import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// How long before a task's due time the reminder fires.
const Duration kReminderLead = Duration(minutes: 30);

/// A stable 31-bit notification id derived from a task's uuid, so scheduling and
/// cancelling always target the same OS notification for a given task.
int notificationIdFor(String uuid) => uuid.hashCode & 0x7fffffff;

/// Local reminders for tasks. The "reminder on" flag is stored per-task in
/// [SharedPreferences] (device-local, not synced); the actual OS notification is
/// scheduled 30 minutes before the task's due time via flutter_local_notifications.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'task_reminders';
  static const _prefsKey = 'alarm_task_uuids';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// uuids of tasks the user has enabled a reminder for. Cached in memory and
  /// mirrored to SharedPreferences.
  Set<String> _enabled = {};

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Fall back to UTC if the platform timezone can't be resolved.
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: darwinInit,
        macOS: darwinInit,
      ),
    );

    final prefs = await SharedPreferences.getInstance();
    _enabled = (prefs.getStringList(_prefsKey) ?? const []).toSet();
    _initialized = true;
  }

  bool isEnabled(String uuid) => _enabled.contains(uuid);

  /// Snapshot of all uuids with a reminder enabled.
  List<String> get enabledUuids => _enabled.toList();

  Future<void> setEnabled(String uuid, bool enabled) async {
    if (enabled) {
      _enabled.add(uuid);
    } else {
      _enabled.remove(uuid);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _enabled.toList());
  }

  /// Ask for notification (Android 13+/iOS) and exact-alarm (Android 12+)
  /// permissions. Safe to call repeatedly. Returns true if notifications are
  /// permitted.
  Future<bool> ensurePermissions() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      // Exact alarms: on Android 12 this may open settings; on 13+ with
      // USE_EXACT_ALARM it's already granted. Best-effort.
      await android.requestExactAlarmsPermission();
      return granted ?? true;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      final granted = await ios.requestPermissions(alert: true, badge: true, sound: true);
      return granted ?? false;
    }
    return true;
  }

  /// Schedule a reminder [kReminderLead] before [due]. No-op (and cancels any
  /// existing one) if that moment is already in the past.
  Future<void> schedule({
    required String uuid,
    required String description,
    required DateTime due,
  }) async {
    final fireAt = due.subtract(kReminderLead);
    final id = notificationIdFor(uuid);
    if (!fireAt.isAfter(DateTime.now())) {
      await _plugin.cancel(id: id);
      return;
    }
    await _plugin.zonedSchedule(
      id: id,
      title: description,
      body: 'Due in ${kReminderLead.inMinutes} minutes',
      scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Task reminders',
          channelDescription: 'Reminders before a task is due',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> cancel(String uuid) =>
      _plugin.cancel(id: notificationIdFor(uuid));
}
