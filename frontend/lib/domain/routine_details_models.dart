import 'nutrition_models.dart';
import 'routine_models.dart';
import 'training_models.dart';

class MarkMeals
{
  final Macros total;
  final List<MealEntry> entries;
  final Macros? dayNorm;

  const MarkMeals({this.total = Macros.zero, this.entries = const [], this.dayNorm});

  factory MarkMeals.fromJson(Map<String, dynamic> aJson) => MarkMeals(
        total: Macros.fromJson(aJson['total']),
        dayNorm: Macros.fromJsonOrNull(aJson['day_norm']),
        entries: (aJson['entries'] as List? ?? const [])
            .map((aItem) => MealEntry.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class MarkDetails
{
  final StatusMarkDto mark;
  final String ownerId;
  final String ownerName;
  final bool isMine;
  final bool isDetailsHidden;
  final WorkoutSession? workout;
  final MarkMeals? meals;

  const MarkDetails({
    required this.mark,
    required this.ownerId,
    this.ownerName = '',
    this.isMine = false,
    this.isDetailsHidden = false,
    this.workout,
    this.meals,
  });

  factory MarkDetails.fromJson(Map<String, dynamic> aJson) => MarkDetails(
        mark: StatusMarkDto.fromJson(aJson['mark'] as Map<String, dynamic>),
        ownerId: aJson['owner_id'] as String,
        ownerName: aJson['owner_name'] as String? ?? '',
        isMine: aJson['is_mine'] as bool? ?? false,
        isDetailsHidden: aJson['is_details_hidden'] as bool? ?? false,
        workout: aJson['workout'] is Map<String, dynamic> ? WorkoutSession.fromJson(aJson['workout'] as Map<String, dynamic>) : null,
        meals: aJson['meals'] is Map<String, dynamic> ? MarkMeals.fromJson(aJson['meals'] as Map<String, dynamic>) : null,
      );
}
