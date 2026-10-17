import 'nutrition_models.dart';
import 'routine_models.dart';
import 'study_models.dart';
import 'training_models.dart';
import 'work_models.dart';

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
  final bool canEdit;
  final bool isDetailsHidden;
  final WorkoutSession? workout;
  final MarkMeals? meals;
  final MarkWork? work;
  final MarkStudy? study;

  const MarkDetails({
    required this.mark,
    required this.ownerId,
    this.ownerName = '',
    this.isMine = false,
    this.canEdit = false,
    this.isDetailsHidden = false,
    this.workout,
    this.meals,
    this.work,
    this.study,
  });

  factory MarkDetails.fromJson(Map<String, dynamic> aJson) => MarkDetails(
        mark: StatusMarkDto.fromJson(aJson['mark'] as Map<String, dynamic>),
        ownerId: aJson['owner_id'] as String,
        ownerName: aJson['owner_name'] as String? ?? '',
        isMine: aJson['is_mine'] as bool? ?? false,
        canEdit: aJson['can_edit'] as bool? ?? aJson['is_mine'] as bool? ?? false,
        isDetailsHidden: aJson['is_details_hidden'] as bool? ?? false,
        workout: aJson['workout'] is Map<String, dynamic> ? WorkoutSession.fromJson(aJson['workout'] as Map<String, dynamic>) : null,
        meals: aJson['meals'] is Map<String, dynamic> ? MarkMeals.fromJson(aJson['meals'] as Map<String, dynamic>) : null,
        work: aJson['work'] is Map<String, dynamic> ? MarkWork.fromJson(aJson['work'] as Map<String, dynamic>) : null,
        study: aJson['study'] is Map<String, dynamic> ? MarkStudy.fromJson(aJson['study'] as Map<String, dynamic>) : null,
      );
}
