import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:taskwand/notifications.dart';
import 'package:taskwand/src/rust/api/tasks.dart';
import 'package:taskwand/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const TaskWandApp());
}

class TaskWandApp extends StatelessWidget {
  const TaskWandApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tasks',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TaskListScreen(),
    );
  }
}

/// Client-side date buckets applied over the fetched task list.
enum DateFilter { all, overdue, today, upcoming, noDate }

extension on DateFilter {
  String get label => switch (this) {
        DateFilter.all => 'All',
        DateFilter.overdue => 'Overdue',
        DateFilter.today => 'Today',
        DateFilter.upcoming => 'Upcoming',
        DateFilter.noDate => 'No date',
      };
}

class Settings {
  final String serverUrl;
  final String clientId;
  final String secret;

  const Settings({
    required this.serverUrl,
    required this.clientId,
    required this.secret,
  });

  bool get hasSync =>
      serverUrl.isNotEmpty && clientId.isNotEmpty && secret.isNotEmpty;
}

Future<Settings> loadSettings() async {
  final prefs = await SharedPreferences.getInstance();
  return Settings(
    serverUrl: prefs.getString('server_url') ?? '',
    clientId: prefs.getString('client_id') ?? '',
    secret: prefs.getString('secret') ?? '',
  );
}

Future<void> saveSettings(Settings s) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('server_url', s.serverUrl);
  await prefs.setString('client_id', s.clientId);
  await prefs.setString('secret', s.secret);
}

// ---- date helpers -----------------------------------------------------------

DateTime? _dueLocal(TaskSummary t) => t.dueUnix == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(t.dueUnix! * 1000);

/// Completion time (local) for a completed task, or null if not completed / unknown.
DateTime? _endLocal(TaskSummary t) => t.endUnix == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(t.endUnix! * 1000);

/// A completed task counts as "recent" for 24h after completion. Recent tasks stay
/// in the list (crossed out, restorable) even when completed tasks are hidden.
bool _completedRecently(TaskSummary t) {
  if (t.status != 'completed') return false;
  final end = _endLocal(t);
  if (end == null) return false;
  return DateTime.now().difference(end) <= const Duration(hours: 24);
}

int _dateToUnix(DateTime d) =>
    DateTime(d.year, d.month, d.day).millisecondsSinceEpoch ~/ 1000;

/// Minutes past local midnight for a due timestamp (0..1439).
int _minutesOfDay(DateTime d) => d.hour * 60 + d.minute;

/// Human-friendly relative label for a due date, with the time of day appended
/// (e.g. "Today · 23:59").
String _formatDue(DateTime due) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final d = DateTime(due.year, due.month, due.day);
  final diff = d.difference(today).inDays;
  final String day;
  if (diff == 0) {
    day = 'Today';
  } else if (diff == 1) {
    day = 'Tomorrow';
  } else if (diff == -1) {
    day = 'Yesterday';
  } else if (diff > 1 && diff < 7) {
    day = DateFormat('EEEE').format(due);
  } else if (due.year == now.year) {
    day = DateFormat('MMM d').format(due);
  } else {
    day = DateFormat('MMM d, y').format(due);
  }
  return '$day · ${DateFormat('HH:mm').format(due)}';
}

// ---- main screen ------------------------------------------------------------

class TaskListScreen extends StatefulWidget {
  const TaskListScreen({super.key});

  @override
  State<TaskListScreen> createState() => _TaskListScreenState();
}

class _TaskListScreenState extends State<TaskListScreen>
    with WidgetsBindingObserver {
  List<TaskSummary> _tasks = [];
  bool _syncing = false;
  bool _initialized = false;
  bool _showCompleted = false;
  DateFilter _filter = DateFilter.all;
  Settings _settings = const Settings(serverUrl: '', clientId: '', secret: '');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _initialized) {
      _syncAndReload();
    }
  }

  Future<void> _startup() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final dbDir = Directory('${docsDir.path}/taskdb');
    if (!dbDir.existsSync()) dbDir.createSync(recursive: true);

    await openReplica(dir: dbDir.path);
    await NotificationService.instance.init();
    _settings = await loadSettings();
    await _reload();
    setState(() => _initialized = true);

    if (_settings.hasSync) _backgroundSync();
  }

  Future<void> _reload() async {
    // Always fetch completed tasks: recently-completed ones (≤24h) stay in the
    // list regardless of the "show completed" toggle — see [_visibleTasks].
    final tasks = await listTasks(includeCompleted: true);
    if (mounted) setState(() => _tasks = tasks);
    await _reconcileAlarms(tasks);
  }

  /// Keep the OS reminders in sync with the task list: (re)schedule a reminder for
  /// every pending, due-dated task the user enabled it for; cancel it once the task
  /// is completed or loses its due date. Also drops reminders for tasks that no
  /// longer exist (e.g. deleted on another device).
  Future<void> _reconcileAlarms(List<TaskSummary> tasks) async {
    final svc = NotificationService.instance;
    final present = <String>{};
    for (final t in tasks) {
      present.add(t.uuid);
      if (!svc.isEnabled(t.uuid)) continue;
      final due = _dueLocal(t);
      if (t.status == 'pending' && due != null) {
        await svc.schedule(
            uuid: t.uuid, description: t.description, due: due);
      } else {
        await svc.cancel(t.uuid);
      }
    }
    for (final uuid in svc.enabledUuids) {
      if (!present.contains(uuid)) {
        await svc.cancel(uuid);
        await svc.setEnabled(uuid, false);
      }
    }
  }

  Future<void> _syncAndReload() async {
    await _performSync();
    await _reload();
  }

  Future<void> _performSync() async {
    if (!_settings.hasSync) return;
    setState(() => _syncing = true);
    try {
      await syncTasks(
        url: _settings.serverUrl,
        clientId: _settings.clientId,
        secret: _settings.secret,
      );
    } catch (e) {
      _snack('Sync failed: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _backgroundSync() {
    _performSync().then((_) {
      if (mounted) _reload();
    });
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  List<TaskSummary> get _visibleTasks {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final tomorrowStart = todayStart.add(const Duration(days: 1));
    bool matches(TaskSummary t) {
      // Completed tasks: recently-completed ones always stay (crossed out); older
      // ones show only when the "show completed" toggle is on.
      if (t.status == 'completed' && !_showCompleted && !_completedRecently(t)) {
        return false;
      }
      final due = _dueLocal(t);
      switch (_filter) {
        case DateFilter.all:
          return true;
        case DateFilter.overdue:
          return due != null && due.isBefore(todayStart);
        case DateFilter.today:
          return due != null &&
              !due.isBefore(todayStart) &&
              due.isBefore(tomorrowStart);
        case DateFilter.upcoming:
          return due != null && !due.isBefore(tomorrowStart);
        case DateFilter.noDate:
          return due == null;
      }
    }

    return _tasks.where(matches).toList();
  }

  Future<void> _toggleComplete(TaskSummary task) async {
    final completing = task.status == 'pending';
    try {
      if (completing) {
        await completeTask(uuid: task.uuid);
      } else {
        await uncompleteTask(uuid: task.uuid);
      }
    } catch (e) {
      _snack('Error: $e');
    }
    await _reload();
    _backgroundSync();
  }

  Future<void> _deleteTask(String uuid, {bool alreadyRemoved = false}) async {
    await NotificationService.instance.cancel(uuid);
    await NotificationService.instance.setEnabled(uuid, false);
    try {
      await deleteTask(uuid: uuid);
    } catch (e) {
      _snack('Error: $e');
      await _reload();
      return;
    }
    if (!alreadyRemoved) await _reload();
    _backgroundSync();
    _snack('Task deleted');
  }

  Future<void> _toggleShowCompleted() async {
    setState(() => _showCompleted = !_showCompleted);
    await _reload();
  }

  Future<void> _openEditor({TaskSummary? existing}) async {
    final result = await showModalBottomSheet<EditorResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TaskEditorSheet(existing: existing),
    );
    if (result == null || !mounted) return;

    if (result.delete && existing != null) {
      await _deleteTask(existing.uuid);
      return;
    }

    try {
      if (existing == null) {
        // Rust generates the uuid; diff the task list before/after to find it, so
        // the reminder flag can be attached to the new task.
        final before = _tasks.map((t) => t.uuid).toSet();
        await addTask(
          description: result.description,
          project: result.project,
          dueUnix: result.dueUnix,
          dueTimeMinutes: result.dueMinutes,
        );
        final after = await listTasks(includeCompleted: true);
        final newUuid = after
            .firstWhere((t) => !before.contains(t.uuid),
                orElse: () => after.first)
            .uuid;
        await NotificationService.instance.setEnabled(newUuid, result.alarm);
      } else {
        await modifyTask(
          uuid: existing.uuid,
          description: result.description,
          project: result.project,
          dueUnix: result.dueUnix,
          dueTimeMinutes: result.dueMinutes,
        );
        await NotificationService.instance
            .setEnabled(existing.uuid, result.alarm);
      }
    } catch (e) {
      _snack('Error: $e');
    }
    await _reload();
    _backgroundSync();
  }

  Future<void> _openSettings() async {
    final result = await showModalBottomSheet<Settings>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SettingsSheet(current: _settings),
    );
    if (result != null) {
      await saveSettings(result);
      setState(() => _settings = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleTasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              onPressed: _syncAndReload,
              tooltip: 'Sync',
            ),
          IconButton(
            icon: Icon(_showCompleted
                ? Icons.check_circle
                : Icons.check_circle_outline),
            onPressed: _toggleShowCompleted,
            tooltip: _showCompleted ? 'Hide completed' : 'Show completed',
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
            tooltip: 'Settings',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          _FilterBar(
            selected: _filter,
            onSelected: (f) => setState(() => _filter = f),
          ),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _syncAndReload,
              child: visible.isEmpty
                  ? _EmptyState(initialized: _initialized)
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) =>
                          const Divider(height: 1, indent: 56),
                      itemBuilder: (context, i) => _TaskTile(
                        task: visible[i],
                        onToggle: () => _toggleComplete(visible[i]),
                        onTap: () => _openEditor(existing: visible[i]),
                        onDismissed: () {
                          final uuid = visible[i].uuid;
                          setState(
                              () => _tasks.removeWhere((t) => t.uuid == uuid));
                          _deleteTask(uuid, alreadyRemoved: true);
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- filter bar -------------------------------------------------------------

class _FilterBar extends StatelessWidget {
  final DateFilter selected;
  final ValueChanged<DateFilter> onSelected;

  const _FilterBar({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final f in DateFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(f.label),
                selected: selected == f,
                onSelected: (_) => onSelected(f),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- task tile --------------------------------------------------------------

class _TaskTile extends StatelessWidget {
  final TaskSummary task;
  final VoidCallback onToggle;
  final VoidCallback onTap;
  final VoidCallback onDismissed;

  const _TaskTile({
    required this.task,
    required this.onToggle,
    required this.onTap,
    required this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final completed = task.status == 'completed';
    final due = _dueLocal(task);
    final overdue = due != null && due.isBefore(DateTime.now()) && !completed;

    final subtitleChildren = <Widget>[];
    if (task.project != null && task.project!.isNotEmpty) {
      subtitleChildren.add(_ProjectChip(label: task.project!));
    }
    if (due != null) {
      subtitleChildren.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.event,
              size: 14,
              color: overdue
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            _formatDue(due),
            style: theme.textTheme.bodySmall?.copyWith(
              color: overdue
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: overdue ? FontWeight.w600 : null,
            ),
          ),
        ],
      ));
    }

    return Dismissible(
      key: ValueKey(task.uuid),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismissed(),
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(Icons.delete_outline,
            color: theme.colorScheme.onErrorContainer),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Checkbox(
          value: completed,
          shape: const CircleBorder(),
          onChanged: (_) => onToggle(),
        ),
        title: Text(
          task.description,
          style: completed
              ? theme.textTheme.bodyLarge?.copyWith(
                  decoration: TextDecoration.lineThrough,
                  color: theme.colorScheme.onSurfaceVariant,
                )
              : null,
        ),
        subtitle: subtitleChildren.isEmpty
            ? null
            : Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: subtitleChildren,
                ),
              ),
        // Completed tasks stay visible but crossed out; offer a one-tap restore
        // back to pending (same action as unchecking the box).
        trailing: completed
            ? IconButton(
                icon: const Icon(Icons.undo),
                tooltip: 'Restore',
                onPressed: onToggle,
              )
            : null,
      ),
    );
  }
}

class _ProjectChip extends StatelessWidget {
  final String label;
  const _ProjectChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool initialized;
  const _EmptyState({required this.initialized});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Wrap in a scrollable so pull-to-refresh still works when the list is empty.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.task_alt,
                    size: 64, color: theme.colorScheme.outlineVariant),
                const SizedBox(height: 12),
                Text(
                  initialized ? 'Nothing here' : 'Loading…',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- task editor sheet ------------------------------------------------------

class EditorResult {
  final bool delete;
  final String description;
  final String? project;
  final int? dueUnix;
  final int? dueMinutes;

  /// Whether the user asked for a reminder 30 minutes before the due time.
  /// Only meaningful when a due date is set.
  final bool alarm;

  const EditorResult({
    this.delete = false,
    this.description = '',
    this.project,
    this.dueUnix,
    this.dueMinutes,
    this.alarm = false,
  });
}

class TaskEditorSheet extends StatefulWidget {
  final TaskSummary? existing;
  const TaskEditorSheet({super.key, this.existing});

  @override
  State<TaskEditorSheet> createState() => _TaskEditorSheetState();
}

class _TaskEditorSheetState extends State<TaskEditorSheet> {
  late final TextEditingController _descCtrl;
  late final TextEditingController _projectCtrl;
  // Date component (local midnight, Unix seconds) and time-of-day (minutes past
  // midnight) are tracked separately so the time picker can be optional.
  int? _dueUnix;
  int? _dueMinutes;
  // Whether a reminder 30 min before due is enabled (device-local flag).
  bool _alarm = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _descCtrl = TextEditingController(text: e?.description ?? '');
    _projectCtrl = TextEditingController(text: e?.project ?? '');
    // Split the stored due timestamp back into its date and time-of-day parts.
    final due = e?.dueUnix;
    if (due != null) {
      final dt = DateTime.fromMillisecondsSinceEpoch(due * 1000);
      _dueUnix = _dateToUnix(dt);
      _dueMinutes = _minutesOfDay(dt);
    }
    if (e != null) _alarm = NotificationService.instance.isEnabled(e.uuid);
  }

  Future<void> _toggleAlarm(bool value) async {
    // Request permission the moment the user opts in, so scheduling later works.
    if (value) {
      final ok = await NotificationService.instance.ensurePermissions();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notifications permission denied')),
        );
      }
    }
    if (mounted) setState(() => _alarm = value);
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _projectCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final initial = _dueUnix != null
        ? DateTime.fromMillisecondsSinceEpoch(_dueUnix! * 1000)
        : DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _dueUnix = _dateToUnix(picked));
  }

  Future<void> _pickTime() async {
    // Default the picker to the effective due time (23:59 when none is set yet).
    final initial = _dueMinutes != null
        ? TimeOfDay(hour: _dueMinutes! ~/ 60, minute: _dueMinutes! % 60)
        : const TimeOfDay(hour: 23, minute: 59);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() => _dueMinutes = picked.hour * 60 + picked.minute);
    }
  }

  void _save() {
    final desc = _descCtrl.text.trim();
    if (desc.isEmpty) return;
    final project = _projectCtrl.text.trim();
    Navigator.pop(
      context,
      EditorResult(
        description: desc,
        project: project.isEmpty ? null : project,
        dueUnix: _dueUnix,
        // Only meaningful with a date; the Rust side defaults a null time to 23:59.
        dueMinutes: _dueUnix == null ? null : _dueMinutes,
        // A reminder only makes sense relative to a due date.
        alarm: _dueUnix != null && _alarm,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEdit = widget.existing != null;
    final due = _dueUnix != null
        ? DateTime.fromMillisecondsSinceEpoch(_dueUnix! * 1000)
        : null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isEdit ? 'Edit task' : 'New task',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              if (isEdit)
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: theme.colorScheme.error),
                  tooltip: 'Delete',
                  onPressed: () => Navigator.pop(
                    context,
                    const EditorResult(delete: true),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            // Only pop the keyboard for a brand-new task. Auto-focusing while editing
            // fights the sheet's open animation (keyboard raise + inset reflow), which
            // drops frames — and when editing you usually just want the date/project.
            autofocus: !isEdit,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Description',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _projectCtrl,
            decoration: const InputDecoration(
              labelText: 'Project (optional)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.folder_outlined),
            ),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Due date',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.event_outlined),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    due != null
                        ? DateFormat('EEE, MMM d, y').format(due)
                        : 'No due date',
                    style: due == null
                        ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                        : null,
                  ),
                ),
                if (due != null)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    tooltip: 'Clear',
                    onPressed: () => setState(() {
                      _dueUnix = null;
                      _dueMinutes = null;
                    }),
                  ),
                TextButton(
                  onPressed: _pickDate,
                  child: Text(due != null ? 'Change' : 'Set'),
                ),
              ],
            ),
          ),
          if (due != null) ...[
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Due time',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.schedule_outlined),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _dueMinutes != null
                          ? TimeOfDay(
                                  hour: _dueMinutes! ~/ 60,
                                  minute: _dueMinutes! % 60)
                              .format(context)
                          : '23:59 (end of day)',
                      style: _dueMinutes == null
                          ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                          : null,
                    ),
                  ),
                  if (_dueMinutes != null)
                    IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      tooltip: 'Reset to end of day',
                      onPressed: () => setState(() => _dueMinutes = null),
                    ),
                  TextButton(
                    onPressed: _pickTime,
                    child: Text(_dueMinutes != null ? 'Change' : 'Set'),
                  ),
                ],
              ),
            ),
          ],
          if (due != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _alarm,
                onChanged: (v) => _toggleAlarm(v ?? false),
                title: const Text('Remind me 30 minutes before'),
                secondary: const Icon(Icons.notifications_outlined),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _save,
            child: Text(isEdit ? 'Save' : 'Add task'),
          ),
        ],
      ),
    );
  }
}

// ---- settings sheet ---------------------------------------------------------

class SettingsSheet extends StatefulWidget {
  final Settings current;
  const SettingsSheet({super.key, required this.current});

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _idCtrl;
  late final TextEditingController _secretCtrl;
  bool _obscureSecret = true;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.current.serverUrl);
    _idCtrl = TextEditingController(text: widget.current.clientId);
    _secretCtrl = TextEditingController(text: widget.current.secret);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _idCtrl.dispose();
    _secretCtrl.dispose();
    super.dispose();
  }

  Settings get _current => Settings(
        serverUrl: _urlCtrl.text.trim(),
        clientId: _idCtrl.text.trim(),
        secret: _secretCtrl.text,
      );

  Future<void> _syncNow() async {
    final s = _current;
    if (!s.hasSync) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fill in all fields first')),
      );
      return;
    }
    setState(() => _syncing = true);
    try {
      await syncTasks(url: s.serverUrl, clientId: s.clientId, secret: s.secret);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync successful')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Sync settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://100.x.y.z:8080',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _idCtrl,
            decoration: const InputDecoration(
              labelText: 'Client ID (UUID)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _secretCtrl,
            decoration: InputDecoration(
              labelText: 'Encryption secret',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _obscureSecret ? Icons.visibility : Icons.visibility_off),
                onPressed: () =>
                    setState(() => _obscureSecret = !_obscureSecret),
              ),
            ),
            obscureText: _obscureSecret,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _syncing ? null : _syncNow,
                  child: _syncing
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sync now'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, _current),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
