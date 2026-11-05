
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'vitals_reading.dart';

enum BandStatus { idle, scanning, connecting, connected }

class VitalsService extends ChangeNotifier {
  // Must match the ESP32 sketch.
  static const String deviceName = 'ESP32_Breathing';

  static final Guid serviceUuid =
      Guid('12345678-1234-1234-1234-123456789000');

  static final Guid characteristicUuid =
      Guid('12345678-1234-1234-1234-123456789001');

  static const Duration staleAfter = Duration(seconds: 3);

  BandStatus status = BandStatus.idle;
  String? error;
  VitalsReading? latest;

  final List<VitalsReading> history = [];

  BluetoothDevice? _device;

  StreamSubscription<List<int>>? _dataSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  Timer? _staleTimer;

  bool _lastLive = false;
  String _buf = '';

  final List<DateTime> _inhaleStarts = [];

  bool get isConnected => status == BandStatus.connected;

  bool get isBusy =>
      status == BandStatus.scanning ||
      status == BandStatus.connecting;

  bool get isLive =>
      isConnected &&
      latest != null &&
      DateTime.now().difference(latest!.at) < staleAfter;

  double? get breathsPerMinute {
    final cutoff = DateTime.now().subtract(
      const Duration(seconds: 90),
    );

    final recent =
        _inhaleStarts.where((t) => t.isAfter(cutoff)).toList();

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
    _setStatus(BandStatus.scanning);

    try {
      // 1. Request Android Bluetooth permissions.
      final scanPermission =
          await Permission.bluetoothScan.request();

      final connectPermission =
          await Permission.bluetoothConnect.request();

      if (!scanPermission.isGranted ||
          !connectPermission.isGranted) {
        throw 'Bluetooth permissions denied. Please allow Nearby Devices permission in Android settings.';
      }

      // 2. Check Bluetooth adapter.
      final adapter = await FlutterBluePlus.adapterState.first;

      if (adapter != BluetoothAdapterState.on) {
        throw 'Turn on Bluetooth and try again.';
      }

      // 3. Scan for ESP32.
      debugPrint('Starting ESP32 scan...');

      final device = await _scanForBand();

      if (device == null) {
        throw 'Band not found. Check that ESP32_Breathing is powered on.';
      }

      debugPrint('ESP32 found: ${device.platformName}');

      _setStatus(BandStatus.connecting);

      // 4. Connect.
      // ignore: deprecated_member_use
      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 15),
      );

      _device = device;

      debugPrint('BLE CONNECTED');

      // 5. Monitor connection state.
      _connSub = device.connectionState.listen((s) {
        debugPrint('BLE CONNECTION STATE: $s');

        if (s == BluetoothConnectionState.disconnected &&
            isConnected) {
          error = 'Band disconnected.';
          _teardown();
          status = BandStatus.idle;
          notifyListeners();
        }
      });

      // 6. Discover services.
      debugPrint('Discovering BLE services...');

      final services = await device.discoverServices();

      for (final s in services) {
        debugPrint('SERVICE: ${s.uuid}');

        for (final c in s.characteristics) {
          debugPrint('CHARACTERISTIC: ${c.uuid}');
        }
      }

      // 7. Find matching service.
      final matchingServices = services.where(
        (s) => s.uuid == serviceUuid,
      );

      if (matchingServices.isEmpty) {
        throw 'Expected BLE service not found: $serviceUuid';
      }

      final service = matchingServices.first;

      // 8. Find matching characteristic.
      final matchingCharacteristics =
          service.characteristics.where(
        (c) => c.uuid == characteristicUuid,
      );

      if (matchingCharacteristics.isEmpty) {
        throw 'Expected BLE characteristic not found: $characteristicUuid';
      }

      final characteristic = matchingCharacteristics.first;

      if (!characteristic.properties.notify &&
          !characteristic.properties.indicate) {
        throw 'The BLE characteristic does not support notifications or indications.';
      }

      debugPrint('Matched BLE service and characteristic.');

      // 9. Subscribe to incoming ESP32 data.
      _buf = '';

      await characteristic.setNotifyValue(true);

      _dataSub =
          characteristic.onValueReceived.listen(_onBytes);

      debugPrint('BLE notifications enabled.');

      // 10. Monitor whether data is arriving.
      _staleTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) {
          final live = isLive;

          if (live != _lastLive) {
            _lastLive = live;
            notifyListeners();
          }
        },
      );

      _setStatus(BandStatus.connected);

      debugPrint('ESP32 BAND READY.');
    } catch (e, stackTrace) {
      debugPrint('FULL BLE ERROR: ${e.toString()}');
      debugPrint('STACK TRACE: $stackTrace');

      error = e.toString();

      final d = _device;

      _teardown();

      try {
        await d?.disconnect();
      } catch (disconnectError) {
        debugPrint('Disconnect cleanup error: $disconnectError');
      }

      _setStatus(BandStatus.idle);
    }
  }

  // -------------------------------------------------------------------------
  // SCAN
  // -------------------------------------------------------------------------

  Future<BluetoothDevice?> _scanForBand() async {
    final found = Completer<BluetoothDevice?>();

    final sub = FlutterBluePlus.onScanResults.listen(
      (results) {
        for (final r in results) {
          final matches =
              r.advertisementData.serviceUuids.contains(serviceUuid) ||
              r.advertisementData.advName == deviceName ||
              r.device.platformName == deviceName;

          if (matches && !found.isCompleted) {
            found.complete(r.device);
          }
        }
      },
    );

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
      );

      return await found.future.timeout(
        const Duration(seconds: 11),
        onTimeout: () => null,
      );
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  // -------------------------------------------------------------------------
  // DISCONNECT
  // -------------------------------------------------------------------------

  Future<void> disconnect() async {
    final d = _device;

    _teardown();

    latest = null;
    history.clear();
    _inhaleStarts.clear();

    error = null;

    _setStatus(BandStatus.idle);

    try {
      await d?.disconnect();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }
  }

  // -------------------------------------------------------------------------
  // INCOMING ESP32 DATA
  // -------------------------------------------------------------------------

  void _onBytes(List<int> bytes) {
    _buf += utf8.decode(bytes, allowMalformed: true);

    int end;

    while ((end = _buf.indexOf('}')) != -1) {
      final raw = _buf.substring(0, end + 1);

      _buf = _buf.substring(end + 1);

      final start = raw.indexOf('{');

      if (start == -1) continue;

      try {
        final json =
            jsonDecode(raw.substring(start)) as Map<String, dynamic>;

        if (!json.containsKey('heart_rate_bpm')) {
          continue;
        }

        _accept(VitalsReading.fromJson(json));
      } catch (e) {
        debugPrint('Skipping bad packet: $e');
      }
    }
  }

  void _accept(VitalsReading r) {
    if (r.phase == 'inhale' &&
        latest?.phase != 'inhale') {
      _inhaleStarts.add(r.at);

      if (_inhaleStarts.length > 12) {
        _inhaleStarts.removeAt(0);
      }
    }

    latest = r;

    history.add(r);

    if (history.length > 240) {
      history.removeAt(0);
    }

    _lastLive = true;

    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // HELPERS
  // -------------------------------------------------------------------------

  void _teardown() {
    _dataSub?.cancel();
    _connSub?.cancel();
    _staleTimer?.cancel();

    _dataSub = null;
    _connSub = null;
    _staleTimer = null;

    _lastLive = false;
    _device = null;
    _buf = '';
  }

  void _setStatus(BandStatus s) {
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}
