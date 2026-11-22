import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'vitals_reading.dart';

enum BandStatus { idle, scanning, connecting, connected }

class VitalsService extends ChangeNotifier {
  // Must match the new ESP32 firmware (Nordic UART Service / NUS).
  static const String deviceName = 'ESP32_Breathing';

  static final Guid serviceUuid =
      Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
  // ESP32 -> phone: notifications containing newline-terminated JSON.
  static final Guid txCharacteristicUuid =
      Guid('6E400003-B5A3-F393-E0A9-E50E24DCCA9E');
  // Phone -> ESP32: write commands, currently 'c' (calibrate) and 'f' (flip).
  static final Guid rxCharacteristicUuid =
      Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');

  static const Duration staleAfter = Duration(seconds: 3);
  static const int _maxBufferLength = 8192;

  BandStatus status = BandStatus.idle;
  String? error;
  VitalsReading? latest;

  final List<VitalsReading> history = [];

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;

  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  Timer? _staleTimer;

  bool _lastLive = false;
  bool _manualDisconnect = false;
  String _buf = '';
  final List<DateTime> _inhaleStarts = [];

  bool get isConnected => status == BandStatus.connected;
  bool get isBusy =>
      status == BandStatus.scanning || status == BandStatus.connecting;

  bool get isLive =>
      isConnected &&
      latest != null &&
      DateTime.now().difference(latest!.at) < staleAfter;

  double? get breathsPerMinute {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 90));
    final recent = _inhaleStarts.where((t) => t.isAfter(cutoff)).toList();
    if (recent.length < 2) return null;

    final spanSec =
        recent.last.difference(recent.first).inMilliseconds / 1000.0;
    if (spanSec <= 0) return null;

    final rate = (recent.length - 1) / spanSec * 60;
    return (rate >= 3 && rate <= 60) ? rate : null;
  }

  // -------------------------------------------------------------------------
  // CONNECT
  // -------------------------------------------------------------------------

  Future<void> connectToBand() async {
    if (status != BandStatus.idle) return;

    error = null;
    _manualDisconnect = false;
    _setStatus(BandStatus.scanning);

    try {
      await _requestBluetoothPermissions();

      final adapter = await FlutterBluePlus.adapterState.first;
      if (adapter != BluetoothAdapterState.on) {
        throw Exception('Turn on Bluetooth and try again.');
      }

      debugPrint('Scanning for $deviceName / NUS service...');
      final device = await _scanForBand();
      if (device == null) {
        throw Exception(
          'Band not found. Check that the new ESP32 is powered on and advertising.',
        );
      }

      debugPrint('ESP32 found: ${device.platformName}');
      _setStatus(BandStatus.connecting);

      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 15),
      );
      _device = device;

      _connSub = device.connectionState.listen((state) {
        debugPrint('BLE CONNECTION STATE: $state');
        if (state == BluetoothConnectionState.disconnected &&
            !_manualDisconnect) {
          _handleUnexpectedDisconnect();
        }
      });

      debugPrint('Discovering BLE services...');
      final services = await device.discoverServices();
      for (final service in services) {
        debugPrint('SERVICE: ${service.uuid}');
        for (final characteristic in service.characteristics) {
          debugPrint('CHARACTERISTIC: ${characteristic.uuid}');
        }
      }

      BluetoothService? service;
      for (final candidate in services) {
        if (candidate.uuid == serviceUuid) {
          service = candidate;
          break;
        }
      }
      if (service == null) {
        throw Exception('New ESP32 NUS service not found: $serviceUuid');
      }

      BluetoothCharacteristic? tx;
      BluetoothCharacteristic? rx;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == txCharacteristicUuid) tx = characteristic;
        if (characteristic.uuid == rxCharacteristicUuid) rx = characteristic;
      }

      if (tx == null) {
        throw Exception('ESP32 TX notification characteristic not found.');
      }
      if (!tx.properties.notify && !tx.properties.indicate) {
        throw Exception('ESP32 TX characteristic does not support notifications.');
      }
      if (rx == null || !rx.properties.write) {
        debugPrint('ESP32 RX write characteristic unavailable; commands disabled.');
      }

      _txCharacteristic = tx;
      _rxCharacteristic = rx;
      _buf = '';

      await tx.setNotifyValue(true);
      _dataSub = tx.onValueReceived.listen(
        _onBytes,
        onError: (Object e) {
          error = 'BLE data stream error: $e';
          notifyListeners();
        },
      );

      _staleTimer?.cancel();
      _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final live = isLive;
        if (live != _lastLive) {
          _lastLive = live;
          notifyListeners();
        }
      });

      _setStatus(BandStatus.connected);
      debugPrint('New ESP32 connected. NUS notifications enabled.');
    } catch (e, stackTrace) {
      debugPrint('FULL BLE ERROR: $e');
      debugPrint('STACK TRACE: $stackTrace');
      error = e.toString();

      final connectedDevice = _device;
      _manualDisconnect = true;
      await _teardown();
      try {
        await connectedDevice?.disconnect();
      } catch (disconnectError) {
        debugPrint('Disconnect cleanup error: $disconnectError');
      }
      _setStatus(BandStatus.idle);
    }
  }

  Future<void> _requestBluetoothPermissions() async {
    // Android 12+ requires Nearby Devices permissions. Older Android versions
    // use location permission for BLE scanning.
    if (defaultTargetPlatform != TargetPlatform.android) return;

    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    if (!scan.isGranted || !connect.isGranted) {
      throw Exception(
        'Bluetooth permissions denied. Allow Nearby Devices permission in Android settings.',
      );
    }
  }

  // -------------------------------------------------------------------------
  // SCAN
  // -------------------------------------------------------------------------

  Future<BluetoothDevice?> _scanForBand() async {
    final found = Completer<BluetoothDevice?>();
    final subscription = FlutterBluePlus.onScanResults.listen((results) {
      for (final result in results) {
        final matches =
            result.advertisementData.serviceUuids.contains(serviceUuid) ||
            result.advertisementData.advName == deviceName ||
            result.device.platformName == deviceName;
        if (matches && !found.isCompleted) {
          found.complete(result.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );

      return await found.future.timeout(
        const Duration(seconds: 11),
        onTimeout: () => null,
      );
    } finally {
      await subscription.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {
        // Scan may already have stopped after its timeout.
      }
    }
  }

  // -------------------------------------------------------------------------
  // PHONE -> ESP32 COMMANDS
  // -------------------------------------------------------------------------

  /// Sends a single-character command supported by the ESP32 firmware.
  /// 'c' starts breathing calibration; 'f' flips inhale/exhale direction.
  Future<void> sendCommand(String command) async {
    if (!isConnected) throw StateError('Connect to the band first.');
    if (command != 'c' && command != 'C' && command != 'f' && command != 'F') {
      throw ArgumentError.value(command, 'command', 'Only c or f is supported.');
    }

    final characteristic = _rxCharacteristic;
    if (characteristic == null || !characteristic.properties.write) {
      throw StateError('The ESP32 command characteristic is unavailable.');
    }

    await characteristic.write(utf8.encode(command), withoutResponse: false);
    debugPrint('Sent ESP32 command: $command');
  }

  Future<void> calibrateBand() => sendCommand('c');
  Future<void> flipBreathingDirection() => sendCommand('f');

  // -------------------------------------------------------------------------
  // DISCONNECT
  // -------------------------------------------------------------------------

  Future<void> disconnect() async {
    final device = _device;
    _manualDisconnect = true;

    await _teardown();
    latest = null;
    history.clear();
    _inhaleStarts.clear();
    error = null;
    _setStatus(BandStatus.idle);

    try {
      await device?.disconnect();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }

  void _handleUnexpectedDisconnect() {
    if (_manualDisconnect || status == BandStatus.idle) return;
    error = 'Band disconnected.';
    unawaited(_teardown());
    status = BandStatus.idle;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // INCOMING ESP32 DATA
  // -------------------------------------------------------------------------

  /// Firmware sends one JSON object followed by '\n'. BLE may split a line
  /// across notifications or deliver multiple lines together, so buffer until
  /// complete newline-delimited messages are available.
  void _onBytes(List<int> bytes) {
    if (bytes.isEmpty) return;

    _buf += utf8.decode(bytes, allowMalformed: true);
    if (_buf.length > _maxBufferLength) {
      debugPrint('BLE receive buffer exceeded limit; discarding incomplete data.');
      final lastNewline = _buf.lastIndexOf('\n');
      _buf = lastNewline >= 0 ? _buf.substring(lastNewline + 1) : '';
    }

    int newline;
    while ((newline = _buf.indexOf('\n')) >= 0) {
      final line = _buf.substring(0, newline).trim();
      _buf = _buf.substring(newline + 1);
      if (line.isEmpty) continue;

      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          debugPrint('Skipping non-object ESP32 packet.');
          continue;
        }
        // The firmware includes these keys even while their values are null.
        if (!decoded.containsKey('phase')) {
          debugPrint('Skipping ESP32 packet without phase.');
          continue;
        }
        _accept(VitalsReading.fromJson(decoded));
      } catch (e) {
        debugPrint('Skipping malformed ESP32 JSON line: $e');
      }
    }
  }

  void _accept(VitalsReading reading) {
    if (reading.phase == 'inhale' && latest?.phase != 'inhale') {
      _inhaleStarts.add(reading.at);
      if (_inhaleStarts.length > 120) _inhaleStarts.removeAt(0);
    }

    latest = reading;
    history.add(reading);
    if (history.length > 240) history.removeAt(0);

    _lastLive = true;
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // HELPERS
  // -------------------------------------------------------------------------

  Future<void> _teardown() async {
    await _dataSub?.cancel();
    await _connSub?.cancel();
    _staleTimer?.cancel();

    _dataSub = null;
    _connSub = null;
    _staleTimer = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _lastLive = false;
    _device = null;
    _buf = '';
  }

  void _setStatus(BandStatus nextStatus) {
    status = nextStatus;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_teardown());
    super.dispose();
  }
}
