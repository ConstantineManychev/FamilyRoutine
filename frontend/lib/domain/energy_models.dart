import 'finance_models.dart';
import 'planner_models.dart';

class EnergyPoint
{
  final DateTime ts;
  final double kcal;

  const EnergyPoint(this.ts, this.kcal);

  factory EnergyPoint.fromJson(Map<String, dynamic> aJson) => EnergyPoint(
        DateTime.parse(aJson['ts'] as String),
        (aJson['kcal'] as num).toDouble(),
      );
}

class EnergyMark
{
  final String id;
  final DateTime ts;
  final double kcal;

  const EnergyMark({required this.id, required this.ts, required this.kcal});

  factory EnergyMark.fromJson(Map<String, dynamic> aJson) => EnergyMark(
        id: aJson['id'] as String,
        ts: DateTime.parse(aJson['ts'] as String),
        kcal: (aJson['kcal'] as num).toDouble(),
      );
}

class EnergyPerson
{
  final String personId;
  final String firstName;
  final String lastName;
  final bool isMe;
  final bool isManaged;
  final bool canEdit;
  final double? dailyBurn;
  final int eaten;
  final int burnedBase;
  final int burnedWorkouts;
  final int startKcal;
  final int balance;
  final List<EnergyPoint> points;
  final List<EnergyMark> marks;

  const EnergyPerson({
    required this.personId,
    required this.firstName,
    required this.lastName,
    this.isMe = false,
    this.isManaged = false,
    this.canEdit = false,
    this.dailyBurn,
    this.eaten = 0,
    this.burnedBase = 0,
    this.burnedWorkouts = 0,
    this.startKcal = 0,
    this.balance = 0,
    this.points = const [],
    this.marks = const [],
  });

  String get fullName => '$firstName $lastName'.trim();

  factory EnergyPerson.fromJson(Map<String, dynamic> aJson) => EnergyPerson(
        personId: aJson['person_id'] as String,
        firstName: aJson['first_name'] as String? ?? '',
        lastName: aJson['last_name'] as String? ?? '',
        isMe: aJson['is_me'] as bool? ?? false,
        isManaged: aJson['is_managed'] as bool? ?? false,
        canEdit: aJson['can_edit'] as bool? ?? false,
        dailyBurn: parseDecimalOrNull(aJson['daily_burn']),
        eaten: (aJson['eaten'] as num? ?? 0).toInt(),
        burnedBase: (aJson['burned_base'] as num? ?? 0).toInt(),
        burnedWorkouts: (aJson['burned_workouts'] as num? ?? 0).toInt(),
        startKcal: (aJson['start_kcal'] as num? ?? 0).toInt(),
        balance: (aJson['balance'] as num? ?? 0).toInt(),
        points: (aJson['points'] as List? ?? const [])
            .map((aItem) => EnergyPoint.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        marks: (aJson['marks'] as List? ?? const [])
            .map((aItem) => EnergyMark.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class EnergyDay
{
  final DateTime date;
  final int days;
  final DateTime dayStart;
  final DateTime dayEnd;
  final List<EnergyPerson> people;

  const EnergyDay({required this.date, this.days = 1, required this.dayStart, required this.dayEnd, this.people = const []});

  factory EnergyDay.fromJson(Map<String, dynamic> aJson) => EnergyDay(
        date: parseDateWire(aJson['date']),
        days: (aJson['days'] as num? ?? 1).toInt(),
        dayStart: DateTime.parse(aJson['day_start'] as String),
        dayEnd: DateTime.parse(aJson['day_end'] as String),
        people: (aJson['people'] as List? ?? const [])
            .map((aItem) => EnergyPerson.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}
