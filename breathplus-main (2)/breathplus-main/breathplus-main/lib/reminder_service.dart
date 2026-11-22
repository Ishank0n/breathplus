import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Schedules one local notification every day at the chosen time.
/// Works offline and with the app closed. Phone only (not Chrome).
class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const _notificationId = 1001;
  static const _kEnabled = 'reminder_enabled';
  static const _kHour = 'reminder_hour';
  static const _kMinute = 'reminder_minute';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// False in Chrome / desktop, where these notifications don't work.
  bool get supported => _isAndroid || _isIOS;

  // ---- Setup ------------------------------------------------------------------
  Future<void> init() async {
    if (!supported || _ready) return;
    try {
      tzdata.initializeTimeZones();
      final timezoneInfo = await FlutterTimezone.getLocalTimezone();

debugPrint('Timezone info: $timezoneInfo');
debugPrint('Timezone identifier: ${timezoneInfo.identifier}');

tz.setLocalLocation(
  tz.getLocation(timezoneInfo.identifier),
);
    } catch (e) {
      debugPrint('Timezone setup failed, using UTC: $e');
    }

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings);
    _ready = true;
  }

  /// Called once at app start: re-schedules the reminder if it was on
  /// (also keeps it right if the phone's time zone changed).
  Future<void> restore() async {
    if (!supported) return;
    try {
      await init();
      final s = await load();
      if (s.enabled) await _schedule(TimeOfDay(hour: s.hour, minute: s.minute));
    } catch (e) {
      debugPrint('Could not restore reminder: $e');
    }
  }

  // ---- Saved settings -------------------------------------------------------
  Future<({bool enabled, int hour, int minute})> load() async {
    final p = await SharedPreferences.getInstance();
    return (
      enabled: p.getBool(_kEnabled) ?? false,
      hour: p.getInt(_kHour) ?? 20,
      minute: p.getInt(_kMinute) ?? 0,
    );
  }

  Future<void> _save({bool? enabled, TimeOfDay? time}) async {
    final p = await SharedPreferences.getInstance();
    if (enabled != null) await p.setBool(_kEnabled, enabled);
    if (time != null) {
      await p.setInt(_kHour, time.hour);
      await p.setInt(_kMinute, time.minute);
    }
  }

  // ---- Public actions ---------------------------------------------------------
  /// Asks for permission, then schedules. Returns false if it couldn't.
  Future<bool> enable(TimeOfDay time) async {
    if (!supported) return false;
    try {
      await init();
      if (!await _requestPermission()) return false;
      await _schedule(time);
      await _save(enabled: true, time: time);
      return true;
    } catch (e) {
      debugPrint('Could not enable reminder: $e');
      return false;
    }
  }

  Future<void> disable() async {
    await _save(enabled: false);
    if (!supported) return;
    try {
      await init();
      await _plugin.cancel(_notificationId);
    } catch (e) {
      debugPrint('Could not cancel reminder: $e');
    }
  }

  /// Saves a new time and re-schedules if the reminder is on.
  Future<void> updateTime(TimeOfDay time) async {
    await _save(time: time);
    if (!supported) return;
    try {
      final s = await load();
      if (s.enabled) {
        await init();
        await _schedule(time);
      }
    } catch (e) {
      debugPrint('Could not update reminder time: $e');
    }
  }

  // ---- Internals --------------------------------------------------------------
  Future<bool> _requestPermission() async {
    if (_isAndroid) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await impl?.requestNotificationsPermission() ?? false;
    }
    final impl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    return await impl?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
  }

  Future<void> _schedule(TimeOfDay time) async {
    final now = tz.TZDateTime.now(tz.local);
    var when = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));

    await _plugin.zonedSchedule(
      _notificationId,
      'Time to breathe',
      'Take a few calm minutes for your breathing session.',
      when,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'daily_reminder',
          'Daily reminder',
          channelDescription: 'Your daily breathing reminder',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Inexact is plenty for a daily nudge and needs no special permission.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time, // repeats every day
    );
  }
}