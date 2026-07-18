import 'dart:convert';

import 'package:home_widget/home_widget.dart';
import 'package:intl/intl.dart';
import 'package:taskwand/src/rust/api/tasks.dart';

// Must match the Kotlin provider class + its fully-qualified name.
const _androidProvider = 'TaskWidgetProvider';
const _qualifiedProvider = 'com.example.taskwand.TaskWidgetProvider';
// Key the widget's RemoteViewsFactory reads from HomeWidget's SharedPreferences.
const _dataKey = 'tw_tasks';

/// Relative due label for the widget row, e.g. "Overdue", "Today · 17:00",
/// "Tomorrow", "Fri · 09:00". Time is dropped for the 23:59 end-of-day default.
String _dueLabel(DateTime due, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final endOfDay = due.hour == 23 && due.minute == 59;
  final time = endOfDay ? '' : ' · ${DateFormat('HH:mm').format(due)}';

  if (due.isBefore(now) && diff < 0) return 'Overdue';
  final String day;
  if (diff == 0) {
    day = 'Today';
  } else if (diff == 1) {
    day = 'Tomorrow';
  } else if (diff > 1 && diff < 7) {
    day = DateFormat('EEE').format(due);
  } else if (due.year == now.year) {
    day = DateFormat('MMM d').format(due);
  } else {
    day = DateFormat('MMM d, y').format(due);
  }
  return '$day$time';
}

/// Push the current task list to the home-screen widget: only pending, due-dated
/// tasks, sorted soonest-first (overdue first). Called after every reload/sync.
Future<void> updateTaskWidget(List<TaskSummary> tasks) async {
  final now = DateTime.now();
  final due = tasks
      .where((t) => t.status == 'pending' && t.dueUnix != null)
      .toList()
    // Total order so refreshes are deterministic: due, then description, then uuid.
    ..sort((a, b) {
      final byDue = a.dueUnix!.compareTo(b.dueUnix!);
      if (byDue != 0) return byDue;
      final byDesc = a.description.compareTo(b.description);
      if (byDesc != 0) return byDesc;
      return a.uuid.compareTo(b.uuid);
    });

  final items = due.take(50).map((t) {
    final d = DateTime.fromMillisecondsSinceEpoch(t.dueUnix! * 1000);
    return {
      'd': t.description,
      'l': _dueLabel(d, now),
      'o': d.isBefore(now), // overdue -> rendered in the error color
    };
  }).toList();

  await HomeWidget.saveWidgetData<String>(_dataKey, jsonEncode(items));
  await HomeWidget.updateWidget(
    androidName: _androidProvider,
    qualifiedAndroidName: _qualifiedProvider,
  );
}
