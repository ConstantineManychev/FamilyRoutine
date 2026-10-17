import 'finance_models.dart';
import 'routine_models.dart';

enum PlanTiming
{
  fixed,
  window;

  static PlanTiming parse(Object? aValue) => aValue == 'window' ? PlanTiming.window : PlanTiming.fixed;
}

enum PlanRepeat
{
  once,
  daily,
  weekly,
  monthly;

  static PlanRepeat parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => PlanRepeat.once);
}

enum PlanState
{
  planned,
  done,
  skipped;

  static PlanState parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => PlanState.planned);
}

String dateWire(DateTime aDate)
{
  String two(int aValue) => aValue.toString().padLeft(2, '0');
  return '${aDate.year.toString().padLeft(4, '0')}-${two(aDate.month)}-${two(aDate.day)}';
}

DateTime parseDateWire(Object? aValue)
{
  final parts = (aValue as String).split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

class ClockTime
{
  final int hour;
  final int minute;

  const ClockTime(this.hour, this.minute);

  factory ClockTime.parse(Object? aValue)
  {
    final parts = (aValue as String).split(':');
    return ClockTime(int.parse(parts[0]), int.parse(parts[1]));
  }

  int get totalMinutes => hour * 60 + minute;

  String get wire => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';

  String get label => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  ClockTime plusMinutes(int aMinutes)
  {
    final total = (totalMinutes + aMinutes) % (24 * 60);
    return ClockTime(total ~/ 60, total % 60);
  }
}

class PlanEvent
{
  final String id;
  final String? ownerId;
  final String title;
  final String? note;
  final RoutineStatus? category;
  final PlanTiming timing;
  final DateTime startDate;
  final ClockTime startTime;
  final int? windowMin;
  final int durationMin;
  final String tz;
  final PlanRepeat repeat;
  final int repeatEvery;
  final int weekdayMask;
  final DateTime? untilDate;
  final String? programId;
  final String? programName;
  final String? dayId;
  final String? dayName;

  const PlanEvent({
    required this.id,
    this.ownerId,
    required this.title,
    this.note,
    this.category,
    required this.timing,
    required this.startDate,
    required this.startTime,
    this.windowMin,
    required this.durationMin,
    required this.tz,
    this.repeat = PlanRepeat.once,
    this.repeatEvery = 1,
    this.weekdayMask = 0,
    this.untilDate,
    this.programId,
    this.programName,
    this.dayId,
    this.dayName,
  });

  factory PlanEvent.fromJson(Map<String, dynamic> aJson) => PlanEvent(
        id: aJson['id'] as String,
        ownerId: aJson['owner_id'] as String?,
        title: aJson['title'] as String,
        note: aJson['note'] as String?,
        category: aJson['category'] == null ? null : RoutineStatus.fromJson(aJson['category']),
        timing: PlanTiming.parse(aJson['timing']),
        startDate: parseDateWire(aJson['start_date']),
        startTime: ClockTime.parse(aJson['start_time']),
        windowMin: (aJson['window_min'] as num?)?.toInt(),
        durationMin: (aJson['duration_min'] as num).toInt(),
        tz: aJson['tz'] as String,
        repeat: PlanRepeat.parse(aJson['repeat']),
        repeatEvery: (aJson['repeat_every'] as num?)?.toInt() ?? 1,
        weekdayMask: (aJson['weekday_mask'] as num?)?.toInt() ?? 0,
        untilDate: aJson['until_date'] == null ? null : parseDateWire(aJson['until_date']),
        programId: aJson['program_id'] as String?,
        programName: aJson['program_name'] as String?,
        dayId: aJson['day_id'] as String?,
        dayName: aJson['day_name'] as String?,
      );

  static Map<String, dynamic> payload({
    required String aTitle,
    String? aNote,
    RoutineStatus? aCategory,
    required PlanTiming aTiming,
    required DateTime aStartDate,
    required ClockTime aStartTime,
    int? aWindowMin,
    required int aDurationMin,
    required String aTz,
    PlanRepeat aRepeat = PlanRepeat.once,
    int aRepeatEvery = 1,
    int aWeekdayMask = 0,
    DateTime? aUntilDate,
    String? aProgramId,
    String? aDayId,
  }) => {
        'title': aTitle,
        if (aNote != null && aNote.trim().isNotEmpty) 'note': aNote.trim(),
        if (aCategory != null) 'category': aCategory.name,
        'timing': aTiming.name,
        'start_date': dateWire(aStartDate),
        'start_time': aStartTime.wire,
        if (aTiming == PlanTiming.window) 'window_min': aWindowMin,
        'duration_min': aDurationMin,
        'tz': aTz,
        'repeat': aRepeat.name,
        'repeat_every': aRepeatEvery,
        'weekday_mask': aWeekdayMask,
        if (aUntilDate != null) 'until_date': dateWire(aUntilDate),
        if (aProgramId != null) 'program_id': aProgramId,
        if (aDayId != null) 'day_id': aDayId,
      };
}

class OccurrenceRef
{
  final String eventId;
  final DateTime occDate;
  final String title;

  const OccurrenceRef({required this.eventId, required this.occDate, required this.title});

  factory OccurrenceRef.fromJson(Map<String, dynamic> aJson) => OccurrenceRef(
        eventId: aJson['event_id'] as String,
        occDate: parseDateWire(aJson['occ_date']),
        title: aJson['title'] as String,
      );
}

class Overload
{
  final int windowMin;
  final int busyMin;

  const Overload({required this.windowMin, required this.busyMin});

  factory Overload.fromJson(Map<String, dynamic> aJson) => Overload(
        windowMin: (aJson['window_min'] as num).toInt(),
        busyMin: (aJson['busy_min'] as num).toInt(),
      );
}

class Occurrence
{
  final String eventId;
  final DateTime occDate;
  final DateTime date;
  final String title;
  final String? note;
  final RoutineStatus? category;
  final PlanTiming timing;
  final DateTime startTs;
  final DateTime endTs;
  final int durationMin;
  final String tz;
  final PlanRepeat repeat;
  final PlanState state;
  final bool isMoved;
  final String? programId;
  final String? dayName;
  final String? sessionId;
  final bool isSessionActive;
  final List<OccurrenceRef> conflicts;
  final Overload? overload;

  const Occurrence({
    required this.eventId,
    required this.occDate,
    required this.date,
    required this.title,
    this.note,
    this.category,
    required this.timing,
    required this.startTs,
    required this.endTs,
    required this.durationMin,
    required this.tz,
    required this.repeat,
    required this.state,
    this.isMoved = false,
    this.programId,
    this.dayName,
    this.sessionId,
    this.isSessionActive = false,
    this.conflicts = const [],
    this.overload,
  });

  bool get isTraining => programId != null;

  bool get isDone => state == PlanState.done;

  bool get isSkipped => state == PlanState.skipped;

  bool get hasIssue => state == PlanState.planned && (conflicts.isNotEmpty || overload != null);

  String get key => '$eventId:${dateWire(occDate)}';

  factory Occurrence.fromJson(Map<String, dynamic> aJson) => Occurrence(
        eventId: aJson['event_id'] as String,
        occDate: parseDateWire(aJson['occ_date']),
        date: parseDateWire(aJson['date']),
        title: aJson['title'] as String,
        note: aJson['note'] as String?,
        category: aJson['category'] == null ? null : RoutineStatus.fromJson(aJson['category']),
        timing: PlanTiming.parse(aJson['timing']),
        startTs: parseTs(aJson['start_ts']),
        endTs: parseTs(aJson['end_ts']),
        durationMin: (aJson['duration_min'] as num).toInt(),
        tz: aJson['tz'] as String,
        repeat: PlanRepeat.parse(aJson['repeat']),
        state: PlanState.parse(aJson['state']),
        isMoved: aJson['is_moved'] as bool? ?? false,
        programId: aJson['program_id'] as String?,
        dayName: aJson['day_name'] as String?,
        sessionId: aJson['session_id'] as String?,
        isSessionActive: aJson['is_session_active'] as bool? ?? false,
        conflicts: (aJson['conflicts'] as List<dynamic>? ?? const [])
            .map((aItem) => OccurrenceRef.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        overload: aJson['overload'] == null ? null : Overload.fromJson(aJson['overload'] as Map<String, dynamic>),
      );
}

class PlanSlot
{
  final String eventId;
  final DateTime occDate;
  final String title;
  final PlanTiming timing;
  final DateTime startTs;
  final DateTime endTs;
  final int durationMin;
  final String? dayName;

  const PlanSlot({
    required this.eventId,
    required this.occDate,
    required this.title,
    required this.timing,
    required this.startTs,
    required this.endTs,
    required this.durationMin,
    this.dayName,
  });

  factory PlanSlot.fromJson(Map<String, dynamic> aJson) => PlanSlot(
        eventId: aJson['event_id'] as String,
        occDate: parseDateWire(aJson['occ_date']),
        title: aJson['title'] as String,
        timing: PlanTiming.parse(aJson['timing']),
        startTs: parseTs(aJson['start_ts']),
        endTs: parseTs(aJson['end_ts']),
        durationMin: (aJson['duration_min'] as num).toInt(),
        dayName: aJson['day_name'] as String?,
      );
}
