import 'finance_models.dart';
import 'planner_models.dart';

enum ScheduleMode
{
  queue,
  intervals,
  weekdays;

  static ScheduleMode parse(Object? aValue)
  {
    for (final mode in ScheduleMode.values)
    {
      if (mode.name == aValue)
      {
        return mode;
      }
    }
    return ScheduleMode.queue;
  }
}

double? _decimalOrNull(Object? aValue) => aValue == null ? null : parseDecimal(aValue);

String? _decimalWire(double? aValue) => aValue?.toStringAsFixed(2);

class ProgramExercise
{
  final String exId;
  final int sets;
  final int? repsMin;
  final int? repsMax;
  final int? durationSec;
  final double? weightKg;
  final int? restSec;
  final double? weightStep;
  final String? note;

  const ProgramExercise({
    required this.exId,
    required this.sets,
    this.repsMin,
    this.repsMax,
    this.durationSec,
    this.weightKg,
    this.restSec,
    this.weightStep,
    this.note,
  });

  factory ProgramExercise.fromJson(Map<String, dynamic> aJson) => ProgramExercise(
        exId: aJson['ex_id'] as String,
        sets: aJson['sets'] as int,
        repsMin: aJson['reps_min'] as int?,
        repsMax: aJson['reps_max'] as int?,
        durationSec: aJson['duration_sec'] as int?,
        weightKg: _decimalOrNull(aJson['weight_kg']),
        restSec: aJson['rest_sec'] as int?,
        weightStep: _decimalOrNull(aJson['weight_step']),
        note: aJson['note'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'ex_id': exId,
        'sets': sets,
        'reps_min': repsMin,
        'reps_max': repsMax,
        'duration_sec': durationSec,
        'weight_kg': _decimalWire(weightKg),
        'rest_sec': restSec,
        'weight_step': _decimalWire(weightStep),
        'note': note,
      };
}

class ProgramDay
{
  final String? id;
  final String name;
  final int restDaysAfter;
  final List<int> weekdays;
  final List<ProgramExercise> exercises;

  const ProgramDay({this.id, required this.name, this.restDaysAfter = 1, this.weekdays = const [], this.exercises = const []});

  factory ProgramDay.fromJson(Map<String, dynamic> aJson) => ProgramDay(
        id: aJson['id'] as String?,
        name: aJson['name'] as String,
        restDaysAfter: aJson['rest_days_after'] as int? ?? 1,
        weekdays: (aJson['weekdays'] as List<dynamic>? ?? const []).map((aItem) => aItem as int).toList(),
        exercises: (aJson['exercises'] as List<dynamic>? ?? const [])
            .map((aItem) => ProgramExercise.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rest_days_after': restDaysAfter,
        'weekdays': weekdays,
        'exercises': exercises.map((aExercise) => aExercise.toJson()).toList(),
      };
}

class TrainingProgram
{
  final String id;
  final String name;
  final ScheduleMode mode;
  final bool isActive;
  final List<ProgramDay> days;

  const TrainingProgram({required this.id, required this.name, required this.mode, required this.isActive, required this.days});

  factory TrainingProgram.fromJson(Map<String, dynamic> aJson) => TrainingProgram(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        mode: ScheduleMode.parse(aJson['schedule_mode']),
        isActive: aJson['is_active'] as bool,
        days: (aJson['days'] as List<dynamic>).map((aItem) => ProgramDay.fromJson(aItem as Map<String, dynamic>)).toList(),
      );
}

class ProgramListItem
{
  final String id;
  final String name;
  final ScheduleMode mode;
  final bool isActive;
  final int dayCount;
  final DateTime? updatedTs;

  const ProgramListItem({
    required this.id,
    required this.name,
    required this.mode,
    required this.isActive,
    required this.dayCount,
    this.updatedTs,
  });

  factory ProgramListItem.fromJson(Map<String, dynamic> aJson) => ProgramListItem(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        mode: ScheduleMode.parse(aJson['schedule_mode']),
        isActive: aJson['is_active'] as bool,
        dayCount: aJson['day_count'] as int,
        updatedTs: aJson['updated_ts'] == null ? null : DateTime.parse(aJson['updated_ts'] as String).toLocal(),
      );
}

class PlannedWorkout
{
  final String dayId;
  final String dayName;
  final DateTime? date;
  final bool isOverdue;

  const PlannedWorkout({required this.dayId, required this.dayName, required this.date, required this.isOverdue});

  factory PlannedWorkout.fromJson(Map<String, dynamic> aJson) => PlannedWorkout(
        dayId: aJson['day_id'] as String,
        dayName: aJson['day_name'] as String,
        date: aJson['date'] == null ? null : DateTime.parse(aJson['date'] as String),
        isOverdue: aJson['is_overdue'] as bool? ?? false,
      );
}

class SessionSummary
{
  final String id;
  final String? programName;
  final String? dayName;
  final DateTime startedTs;
  final DateTime? finishedTs;
  final double? kcal;
  final int doneSets;
  final double volumeKg;

  const SessionSummary({
    required this.id,
    required this.programName,
    required this.dayName,
    required this.startedTs,
    required this.finishedTs,
    required this.kcal,
    required this.doneSets,
    required this.volumeKg,
  });

  Duration? get duration => finishedTs?.difference(startedTs);

  factory SessionSummary.fromJson(Map<String, dynamic> aJson) => SessionSummary(
        id: aJson['id'] as String,
        programName: aJson['program_name'] as String?,
        dayName: aJson['day_name'] as String?,
        startedTs: parseTs(aJson['started_ts']),
        finishedTs: parseTsOrNull(aJson['finished_ts']),
        kcal: _decimalOrNull(aJson['kcal']),
        doneSets: aJson['done_sets'] as int,
        volumeKg: parseDecimal(aJson['volume_kg']),
      );
}

class TrainingPlan
{
  final ProgramListItem? program;
  final List<PlannedWorkout> upcoming;
  final String? activeSessionId;
  final SessionSummary? lastSession;
  final PlanSlot? nextSlot;

  const TrainingPlan({
    required this.program,
    required this.upcoming,
    required this.activeSessionId,
    required this.lastSession,
    this.nextSlot,
  });

  PlannedWorkout? get next => upcoming.isEmpty ? null : upcoming.first;

  factory TrainingPlan.fromJson(Map<String, dynamic> aJson) => TrainingPlan(
        program: aJson['program'] == null ? null : ProgramListItem.fromJson(aJson['program'] as Map<String, dynamic>),
        upcoming: (aJson['upcoming'] as List<dynamic>).map((aItem) => PlannedWorkout.fromJson(aItem as Map<String, dynamic>)).toList(),
        activeSessionId: aJson['active_session_id'] as String?,
        lastSession:
            aJson['last_session'] == null ? null : SessionSummary.fromJson(aJson['last_session'] as Map<String, dynamic>),
        nextSlot: aJson['next_slot'] == null ? null : PlanSlot.fromJson(aJson['next_slot'] as Map<String, dynamic>),
      );
}

class PersonTraining
{
  final TrainingPlan plan;
  final TrainingProgram? program;
  final List<SessionSummary> sessions;

  const PersonTraining({required this.plan, required this.program, required this.sessions});

  factory PersonTraining.fromJson(Map<String, dynamic> aJson) => PersonTraining(
        plan: TrainingPlan.fromJson(aJson['plan'] as Map<String, dynamic>),
        program: aJson['program'] == null ? null : TrainingProgram.fromJson(aJson['program'] as Map<String, dynamic>),
        sessions: (aJson['sessions'] as List<dynamic>).map((aItem) => SessionSummary.fromJson(aItem as Map<String, dynamic>)).toList(),
      );
}

class SessionSet
{
  int? reps;
  double? weightKg;
  int? durationSec;
  bool isDone;

  SessionSet({this.reps, this.weightKg, this.durationSec, this.isDone = false});

  factory SessionSet.fromJson(Map<String, dynamic> aJson) => SessionSet(
        reps: aJson['reps'] as int?,
        weightKg: _decimalOrNull(aJson['weight_kg']),
        durationSec: aJson['duration_sec'] as int?,
        isDone: aJson['is_done'] as bool? ?? false,
      );

  SessionSet copy() => SessionSet(reps: reps, weightKg: weightKg, durationSec: durationSec);

  Map<String, dynamic> toJson() => {
        'reps': reps,
        'weight_kg': _decimalWire(weightKg),
        'duration_sec': durationSec,
        'is_done': isDone,
      };
}

enum ProgressionKind
{
  increaseWeight,
  addReps,
  deload,
  addTime,
  bodyweightTop,
  hold;

  static ProgressionKind? parse(Object? aValue) => switch (aValue)
  {
    'increase_weight' => ProgressionKind.increaseWeight,
    'add_reps' => ProgressionKind.addReps,
    'deload' => ProgressionKind.deload,
    'add_time' => ProgressionKind.addTime,
    'bodyweight_top' => ProgressionKind.bodyweightTop,
    'hold' => ProgressionKind.hold,
    _ => null,
  };
}

class ProgressionAdvice
{
  final ProgressionKind kind;
  final double? from;
  final double? to;

  const ProgressionAdvice({required this.kind, this.from, this.to});

  static ProgressionAdvice? fromJson(Object? aJson)
  {
    if (aJson is! Map<String, dynamic>)
    {
      return null;
    }
    final kind = ProgressionKind.parse(aJson['kind']);
    return kind == null ? null : ProgressionAdvice(kind: kind, from: _decimalOrNull(aJson['from']), to: _decimalOrNull(aJson['to']));
  }
}

enum ProgressMeasure
{
  weight,
  reps,
  duration;

  static ProgressMeasure parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => ProgressMeasure.weight);
}

class ProgressPoint
{
  final String sessionId;
  final DateTime startedTs;
  final String? dayName;
  final double? e1rmKg;
  final double? topWeightKg;
  final int? topReps;
  final int? bestDurationSec;
  final int totalReps;
  final double volumeKg;

  const ProgressPoint({
    required this.sessionId,
    required this.startedTs,
    this.dayName,
    this.e1rmKg,
    this.topWeightKg,
    this.topReps,
    this.bestDurationSec,
    this.totalReps = 0,
    this.volumeKg = 0,
  });

  double? valueOf(ProgressMeasure aMeasure) => switch (aMeasure)
  {
    ProgressMeasure.weight => e1rmKg ?? topWeightKg,
    ProgressMeasure.reps => topReps?.toDouble(),
    ProgressMeasure.duration => bestDurationSec?.toDouble(),
  };

  factory ProgressPoint.fromJson(Map<String, dynamic> aJson) => ProgressPoint(
        sessionId: aJson['session_id'] as String,
        startedTs: parseTs(aJson['started_ts']),
        dayName: aJson['day_name'] as String?,
        e1rmKg: _decimalOrNull(aJson['e1rm_kg']),
        topWeightKg: _decimalOrNull(aJson['top_weight_kg']),
        topReps: aJson['top_reps'] as int?,
        bestDurationSec: aJson['best_duration_sec'] as int?,
        totalReps: aJson['total_reps'] as int? ?? 0,
        volumeKg: _decimalOrNull(aJson['volume_kg']) ?? 0,
      );
}

class ExerciseProgress
{
  final String exId;
  final String? exCode;
  final String exName;
  final ProgressMeasure measure;
  final List<ProgressPoint> points;

  const ExerciseProgress({required this.exId, this.exCode, required this.exName, required this.measure, required this.points});

  factory ExerciseProgress.fromJson(Map<String, dynamic> aJson) => ExerciseProgress(
        exId: aJson['ex_id'] as String,
        exCode: aJson['ex_code'] as String?,
        exName: aJson['ex_name'] as String,
        measure: ProgressMeasure.parse(aJson['measure']),
        points: (aJson['points'] as List<dynamic>).map((aItem) => ProgressPoint.fromJson(aItem as Map<String, dynamic>)).toList(),
      );
}

class SessionExercise
{
  final String exId;
  final String? exCode;
  final String exName;
  final String exType;
  final int? repsMin;
  final int? repsMax;
  final int? durationSec;
  final double? targetWeight;
  final int? restSec;
  final List<SessionSet> sets;
  final List<SessionSet> previous;
  final DateTime? previousTs;
  final ProgressionAdvice? advice;

  SessionExercise({
    required this.exId,
    required this.exCode,
    required this.exName,
    required this.exType,
    this.repsMin,
    this.repsMax,
    this.durationSec,
    this.targetWeight,
    this.restSec,
    required this.sets,
    this.previous = const [],
    this.previousTs,
    this.advice,
  });

  bool get isTimed => durationSec != null || exType == 'cardio' || exType == 'flexibility';

  factory SessionExercise.fromJson(Map<String, dynamic> aJson) => SessionExercise(
        exId: aJson['ex_id'] as String,
        exCode: aJson['ex_code'] as String?,
        exName: aJson['ex_name'] as String,
        exType: aJson['ex_type'] as String? ?? 'strength',
        repsMin: aJson['reps_min'] as int?,
        repsMax: aJson['reps_max'] as int?,
        durationSec: aJson['duration_sec'] as int?,
        targetWeight: _decimalOrNull(aJson['target_weight']),
        restSec: aJson['rest_sec'] as int?,
        sets: (aJson['sets'] as List<dynamic>).map((aItem) => SessionSet.fromJson(aItem as Map<String, dynamic>)).toList(),
        previous: (aJson['previous'] as List<dynamic>? ?? const [])
            .map((aItem) => SessionSet.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        previousTs: parseTsOrNull(aJson['previous_ts']),
        advice: ProgressionAdvice.fromJson(aJson['advice']),
      );

  Map<String, dynamic> toJson() => {
        'ex_id': exId,
        'reps_min': repsMin,
        'reps_max': repsMax,
        'duration_sec': durationSec,
        'target_weight': _decimalWire(targetWeight),
        'rest_sec': restSec,
        'sets': sets.map((aSet) => aSet.toJson()).toList(),
      };
}

class WorkoutSession
{
  final String id;
  final String? programName;
  final String? dayName;
  final DateTime startedTs;
  final DateTime? finishedTs;
  final int? intensity;
  final double? kcal;
  final String? note;
  final List<SessionExercise> exercises;

  const WorkoutSession({
    required this.id,
    required this.programName,
    required this.dayName,
    required this.startedTs,
    required this.finishedTs,
    required this.intensity,
    required this.kcal,
    required this.note,
    required this.exercises,
  });

  bool get isFinished => finishedTs != null;

  factory WorkoutSession.fromJson(Map<String, dynamic> aJson) => WorkoutSession(
        id: aJson['id'] as String,
        programName: aJson['program_name'] as String?,
        dayName: aJson['day_name'] as String?,
        startedTs: parseTs(aJson['started_ts']),
        finishedTs: parseTsOrNull(aJson['finished_ts']),
        intensity: aJson['intensity'] as int?,
        kcal: _decimalOrNull(aJson['kcal']),
        note: aJson['note'] as String?,
        exercises: (aJson['exercises'] as List<dynamic>).map((aItem) => SessionExercise.fromJson(aItem as Map<String, dynamic>)).toList(),
      );
}
