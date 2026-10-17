import 'finance_models.dart';
import 'planner_models.dart';

enum TaskKind
{
  general,
  day;

  static TaskKind parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => TaskKind.general);
}

enum TaskEventKind
{
  created,
  edited,
  progress,
  done,
  reopened,
  deleted;

  static TaskEventKind parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => TaskEventKind.edited);
}

enum TaskField
{
  title,
  note,
  kind,
  date;

  static TaskField? parse(Object? aValue)
  {
    for (final field in values)
    {
      if (field.name == aValue)
      {
        return field;
      }
    }
    return null;
  }
}

enum TaskAction
{
  progress,
  done,
  reopen,
}

class WorkTask
{
  final String id;
  final TaskKind kind;
  final String title;
  final String? note;
  final DateTime startOn;
  final DateTime? doneOn;
  final DateTime? doneTs;
  final DateTime? deletedTs;
  final DateTime createdTs;
  final DateTime updatedTs;
  final String? lastReport;
  final DateTime? lastReportTs;
  final int reportCount;

  const WorkTask({
    required this.id,
    required this.kind,
    required this.title,
    this.note,
    required this.startOn,
    this.doneOn,
    this.doneTs,
    this.deletedTs,
    required this.createdTs,
    required this.updatedTs,
    this.lastReport,
    this.lastReportTs,
    this.reportCount = 0,
  });

  bool get isDone => doneOn != null;

  bool get isArchived => deletedTs != null;

  bool isDoneOn(DateTime aDay) => doneOn != null && !doneOn!.isAfter(aDay);

  int carriedDays(DateTime aDay) => kind == TaskKind.general ? aDay.difference(startOn).inDays : 0;

  factory WorkTask.fromJson(Map<String, dynamic> aJson) => WorkTask(
        id: aJson['id'] as String,
        kind: TaskKind.parse(aJson['kind']),
        title: aJson['title'] as String? ?? '',
        note: aJson['note'] as String?,
        startOn: parseDateWire(aJson['start_on']),
        doneOn: aJson['done_on'] == null ? null : parseDateWire(aJson['done_on']),
        doneTs: parseTsOrNull(aJson['done_ts']),
        deletedTs: parseTsOrNull(aJson['deleted_ts']),
        createdTs: parseTs(aJson['created_ts']),
        updatedTs: parseTs(aJson['updated_ts']),
        lastReport: aJson['last_report'] as String?,
        lastReportTs: parseTsOrNull(aJson['last_report_ts']),
        reportCount: (aJson['report_count'] as num?)?.toInt() ?? 0,
      );
}

class TaskEvent
{
  final String id;
  final TaskEventKind kind;
  final TaskField? field;
  final String? oldValue;
  final String? newValue;
  final String? report;
  final DateTime eventOn;
  final DateTime eventTs;
  final String? statusMarkId;

  const TaskEvent({
    required this.id,
    required this.kind,
    this.field,
    this.oldValue,
    this.newValue,
    this.report,
    required this.eventOn,
    required this.eventTs,
    this.statusMarkId,
  });

  factory TaskEvent.fromJson(Map<String, dynamic> aJson) => TaskEvent(
        id: aJson['id'] as String,
        kind: TaskEventKind.parse(aJson['kind']),
        field: TaskField.parse(aJson['field']),
        oldValue: aJson['old_value'] as String?,
        newValue: aJson['new_value'] as String?,
        report: aJson['report'] as String?,
        eventOn: parseDateWire(aJson['event_on']),
        eventTs: parseTs(aJson['event_ts']),
        statusMarkId: aJson['status_mark_id'] as String?,
      );
}

List<WorkTask> _tasks(Object? aJson) =>
    (aJson as List? ?? const []).map((aItem) => WorkTask.fromJson(aItem as Map<String, dynamic>)).toList();

class WorkDay
{
  final DateTime date;
  final List<WorkTask> general;
  final List<WorkTask> day;

  const WorkDay({required this.date, this.general = const [], this.day = const []});

  factory WorkDay.fromJson(Map<String, dynamic> aJson) => WorkDay(
        date: parseDateWire(aJson['date']),
        general: _tasks(aJson['general']),
        day: _tasks(aJson['day']),
      );

  List<WorkTask> get all => [...day, ...general];

  int get openCount => all.where((aTask) => !aTask.isDoneOn(date)).length;
}

class TaskDetails
{
  final WorkTask task;
  final List<TaskEvent> events;

  const TaskDetails({required this.task, this.events = const []});

  factory TaskDetails.fromJson(Map<String, dynamic> aJson) => TaskDetails(
        task: WorkTask.fromJson(aJson['task'] as Map<String, dynamic>),
        events: (aJson['events'] as List? ?? const [])
            .map((aItem) => TaskEvent.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class BlockLog
{
  final String taskId;
  final String taskTitle;
  final TaskEventKind kind;
  final String? report;
  final DateTime eventTs;

  const BlockLog({required this.taskId, required this.taskTitle, required this.kind, this.report, required this.eventTs});

  factory BlockLog.fromJson(Map<String, dynamic> aJson) => BlockLog(
        taskId: aJson['task_id'] as String,
        taskTitle: aJson['task_title'] as String? ?? '',
        kind: TaskEventKind.parse(aJson['kind']),
        report: aJson['report'] as String?,
        eventTs: parseTs(aJson['event_ts']),
      );
}

class MarkWork
{
  final WorkDay day;
  final List<BlockLog> logged;

  const MarkWork({required this.day, this.logged = const []});

  factory MarkWork.fromJson(Map<String, dynamic> aJson) => MarkWork(
        day: WorkDay.fromJson(aJson),
        logged: (aJson['logged'] as List? ?? const [])
            .map((aItem) => BlockLog.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class TaskDraft
{
  final TaskKind kind;
  final String title;
  final String? note;
  final DateTime date;

  const TaskDraft({required this.kind, required this.title, this.note, required this.date});

  Map<String, dynamic> toJson()
  {
    final note = this.note?.trim();
    return {
      'kind': kind.name,
      'title': title.trim(),
      'note': note == null || note.isEmpty ? null : note,
      'date': dateWire(date),
    };
  }
}
