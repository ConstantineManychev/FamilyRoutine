import 'finance_models.dart';
import 'nutrition_models.dart';
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
  final PlanContent content;

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
    this.content = PlanContent.empty,
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
        content: PlanContent.fromJson(aJson['content']),
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
    Map<String, dynamic> aContent = const {},
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
        'content': aContent,
      };
}

class PlanFood
{
  final String id;
  final MealSource source;
  final String? itemId;
  final String? dishId;
  final String? catId;
  final String? title;
  final double? grams;
  final double? portions;
  final bool isMl;
  final Macros total;

  const PlanFood({
    required this.id,
    required this.source,
    this.itemId,
    this.dishId,
    this.catId,
    this.title,
    this.grams,
    this.portions,
    this.isMl = false,
    this.total = Macros.zero,
  });

  factory PlanFood.fromJson(Map<String, dynamic> aJson) => PlanFood(
        id: aJson['id'] as String,
        source: MealSource.parse(aJson['source']),
        itemId: aJson['item_id'] as String?,
        dishId: aJson['dish_id'] as String?,
        catId: aJson['cat_id'] as String?,
        title: aJson['title'] as String?,
        grams: parseDecimalOrNull(aJson['grams']),
        portions: parseDecimalOrNull(aJson['portions']),
        isMl: aJson['is_ml'] as bool? ?? false,
        total: Macros.fromJson(aJson['total']),
      );

  Map<String, dynamic> get input => switch (source)
      {
        MealSource.quick => {
            'quick': {
              'title': title,
              'kcal': amountWire(total.kcal),
              'prot': amountWire(total.prot),
              'fat': amountWire(total.fat),
              'carb': amountWire(total.carb),
            },
          },
        _ => {
            if (itemId != null) 'item_id': itemId,
            if (dishId != null) 'dish_id': dishId,
            if (catId != null) 'cat_id': catId,
            if (portions != null) 'portions': amountWire(portions!) else 'grams': amountWire(grams ?? 0),
          },
      };
}

String amountWire(double aValue) => aValue == aValue.roundToDouble() ? aValue.toStringAsFixed(0) : aValue.toString();

class PlanTask
{
  final String? id;
  final String title;

  const PlanTask({this.id, required this.title});

  factory PlanTask.fromJson(Map<String, dynamic> aJson) => PlanTask(id: aJson['id'] as String?, title: aJson['title'] as String);
}

class PlanStudy
{
  final String? id;
  final String topicId;
  final String topicTitle;
  final String? note;

  const PlanStudy({this.id, required this.topicId, required this.topicTitle, this.note});

  factory PlanStudy.fromJson(Map<String, dynamic> aJson) => PlanStudy(
        id: aJson['id'] as String?,
        topicId: aJson['topic_id'] as String,
        topicTitle: aJson['topic_title'] as String? ?? '',
        note: aJson['note'] as String?,
      );
}

class PlanContent
{
  final List<PlanFood> foods;
  final Macros total;
  final List<PlanTask> tasks;
  final List<PlanStudy> studies;

  const PlanContent({this.foods = const [], this.total = Macros.zero, this.tasks = const [], this.studies = const []});

  static const PlanContent empty = PlanContent();

  bool get isEmpty => foods.isEmpty && tasks.isEmpty && studies.isEmpty;

  factory PlanContent.fromJson(Object? aJson)
  {
    if (aJson is! Map<String, dynamic>)
    {
      return empty;
    }
    return PlanContent(
      foods: (aJson['foods'] as List? ?? const []).map((aItem) => PlanFood.fromJson(aItem as Map<String, dynamic>)).toList(),
      total: Macros.fromJsonOrNull(aJson['total']) ?? Macros.zero,
      tasks: (aJson['tasks'] as List? ?? const []).map((aItem) => PlanTask.fromJson(aItem as Map<String, dynamic>)).toList(),
      studies: (aJson['studies'] as List? ?? const [])
          .map((aItem) => PlanStudy.fromJson(aItem as Map<String, dynamic>))
          .toList(),
    );
  }
}

class OccurrenceDetails
{
  final Occurrence occurrence;
  final String ownerId;
  final bool isCustom;
  final PlanContent content;
  final String? programName;
  final String? dayId;
  final String? dayName;

  const OccurrenceDetails({
    required this.occurrence,
    required this.ownerId,
    this.isCustom = false,
    this.content = PlanContent.empty,
    this.programName,
    this.dayId,
    this.dayName,
  });

  factory OccurrenceDetails.fromJson(Map<String, dynamic> aJson) => OccurrenceDetails(
        occurrence: Occurrence.fromJson(aJson['occurrence'] as Map<String, dynamic>),
        ownerId: aJson['owner_id'] as String,
        isCustom: aJson['is_custom'] as bool? ?? false,
        content: PlanContent.fromJson(aJson['content']),
        programName: aJson['program_name'] as String?,
        dayId: aJson['day_id'] as String?,
        dayName: aJson['day_name'] as String?,
      );
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
  final String? statusMarkId;
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
    this.statusMarkId,
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
        statusMarkId: aJson['status_mark_id'] as String?,
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
