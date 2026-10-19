import 'finance_models.dart';
import 'planner_models.dart';
import 'profile_models.dart';
import 'routine_models.dart';

enum MealKind
{
  breakfast(4),
  secondBreakfast(9),
  lunch(12),
  afternoonSnack(16),
  dinner(18),
  nightSnack(22);

  final int fromHour;

  const MealKind(this.fromHour);

  static MealKind forTime(DateTime aTs)
  {
    final hour = aTs.hour;
    if (hour < breakfast.fromHour)
    {
      return nightSnack;
    }
    return values.lastWhere((aKind) => hour >= aKind.fromHour);
  }
}

enum MealSource
{
  item,
  dish,
  quick;

  static MealSource parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => MealSource.quick);
}

enum NormGap
{
  weight,
  height,
  sex,
  activity;

  static NormGap? parse(Object? aValue)
  {
    for (final gap in values)
    {
      if (gap.name == aValue)
      {
        return gap;
      }
    }
    return null;
  }
}

class Macros
{
  final double kcal;
  final double prot;
  final double fat;
  final double carb;

  const Macros({this.kcal = 0, this.prot = 0, this.fat = 0, this.carb = 0});

  static const Macros zero = Macros();

  factory Macros.fromJson(Object? aJson)
  {
    if (aJson is! Map<String, dynamic>)
    {
      return zero;
    }
    return Macros(
      kcal: parseDecimal(aJson['kcal']),
      prot: parseDecimal(aJson['prot']),
      fat: parseDecimal(aJson['fat']),
      carb: parseDecimal(aJson['carb']),
    );
  }

  static Macros? fromJsonOrNull(Object? aJson) => aJson is Map<String, dynamic> ? Macros.fromJson(aJson) : null;

  factory Macros.fromNutrition(NutritionData aNutrition) => Macros(
        kcal: aNutrition.kcal ?? 0,
        prot: aNutrition.prot ?? 0,
        fat: aNutrition.fat ?? 0,
        carb: aNutrition.carb ?? 0,
      );

  Macros operator +(Macros aOther) => Macros(
        kcal: kcal + aOther.kcal,
        prot: prot + aOther.prot,
        fat: fat + aOther.fat,
        carb: carb + aOther.carb,
      );

  Macros forGrams(double aGrams)
  {
    final factor = aGrams / 100;
    return Macros(kcal: kcal * factor, prot: prot * factor, fat: fat * factor, carb: carb * factor);
  }
}

class DishIngredient
{
  final String itemId;
  final String itemName;
  final ItemUnit unit;
  final double? pieceG;
  final double grams;
  final Macros? per100;

  const DishIngredient({
    required this.itemId,
    required this.itemName,
    this.unit = ItemUnit.kilogram,
    this.pieceG,
    required this.grams,
    this.per100,
  });

  factory DishIngredient.fromJson(Map<String, dynamic> aJson) => DishIngredient(
        itemId: aJson['item_id'] as String,
        itemName: aJson['item_name'] as String? ?? '',
        unit: ItemUnit.parse(aJson['unit']),
        pieceG: parseDecimalOrNull(aJson['piece_g']),
        grams: parseDecimal(aJson['grams']),
        per100: Macros.fromJsonOrNull(aJson['per_100']),
      );

  factory DishIngredient.fromItem(DictItemDto aItem, double aGrams) => DishIngredient(
        itemId: aItem.id,
        itemName: aItem.name,
        unit: aItem.unit,
        pieceG: aItem.nutrition.pieceG,
        grams: aGrams,
        per100: aItem.nutrition.kcal == null ? null : Macros.fromNutrition(aItem.nutrition),
      );

  DishIngredient withGrams(double aGrams) => DishIngredient(
        itemId: itemId,
        itemName: itemName,
        unit: unit,
        pieceG: pieceG,
        grams: aGrams,
        per100: per100,
      );

  Macros get total => per100?.forGrams(grams) ?? Macros.zero;

  Map<String, dynamic> toJson() => {'item_id': itemId, 'grams': grams.toString()};
}

class DishMath
{
  final double rawG;
  final double cookedG;
  final Macros total;
  final Macros per100;
  final double? portionG;
  final int missingCount;

  const DishMath({
    required this.rawG,
    required this.cookedG,
    required this.total,
    required this.per100,
    this.portionG,
    this.missingCount = 0,
  });

  factory DishMath.compute(List<DishIngredient> aIngredients, {double? aCookedG, double? aServingG, int? aServings})
  {
    final rawG = aIngredients.fold<double>(0, (aSum, aItem) => aSum + aItem.grams);
    final cookedG = aCookedG ?? rawG;
    final total = aIngredients.fold<Macros>(Macros.zero, (aSum, aItem) => aSum + aItem.total);
    final per100 = cookedG > 0 ? total.forGrams(100 * 100 / cookedG) : Macros.zero;
    final servings = aServings;
    return DishMath(
      rawG: rawG,
      cookedG: cookedG,
      total: total,
      per100: per100,
      portionG: aServingG ?? (servings != null && servings > 0 ? cookedG / servings : null),
      missingCount: aIngredients.where((aItem) => aItem.per100 == null).length,
    );
  }
}

class Dish
{
  final String id;
  final String name;
  final String? note;
  final double rawG;
  final double cookedG;
  final bool isCookedSet;
  final double? servingG;
  final int? servings;
  final double? portionG;
  final Macros per100;
  final Macros total;
  final int ingredientCount;
  final int missingCount;
  final bool isShared;
  final bool isEditable;
  final String? ownerName;
  final List<DishIngredient> ingredients;

  const Dish({
    required this.id,
    required this.name,
    this.note,
    required this.rawG,
    required this.cookedG,
    this.isCookedSet = false,
    this.servingG,
    this.servings,
    this.portionG,
    required this.per100,
    this.total = Macros.zero,
    this.ingredientCount = 0,
    this.missingCount = 0,
    this.isShared = false,
    this.isEditable = true,
    this.ownerName,
    this.ingredients = const [],
  });

  factory Dish.fromJson(Map<String, dynamic> aJson) => Dish(
        id: aJson['id'] as String,
        name: aJson['name'] as String? ?? '',
        note: aJson['note'] as String?,
        rawG: parseDecimal(aJson['raw_g']),
        cookedG: parseDecimal(aJson['cooked_g']),
        isCookedSet: aJson['is_cooked_set'] as bool? ?? false,
        servingG: parseDecimalOrNull(aJson['serving_g']),
        servings: (aJson['servings'] as num?)?.toInt(),
        portionG: parseDecimalOrNull(aJson['portion_g']),
        per100: Macros.fromJson(aJson['per_100']),
        total: Macros.fromJson(aJson['total']),
        ingredientCount: (aJson['ingredient_count'] as num?)?.toInt() ?? 0,
        missingCount: (aJson['missing_count'] as num?)?.toInt() ?? 0,
        isShared: aJson['is_shared'] as bool? ?? false,
        isEditable: aJson['is_editable'] as bool? ?? false,
        ownerName: aJson['owner_name'] as String?,
        ingredients: (aJson['ingredients'] as List? ?? const [])
            .map((aItem) => DishIngredient.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  static Map<String, dynamic> payload({
    required String aName,
    String? aNote,
    double? aCookedG,
    double? aServingG,
    int? aServings,
    bool aIsShared = false,
    required List<DishIngredient> aIngredients,
  }) =>
      {
        'name': aName,
        'note': aNote,
        'cooked_g': aCookedG?.toString(),
        'serving_g': aServingG?.toString(),
        'servings': aServings,
        'is_shared': aIsShared,
        'ingredients': aIngredients.map((aItem) => aItem.toJson()).toList(),
      };
}

class MealEntry
{
  final String id;
  final DateTime date;
  final MealSource source;
  final String? itemId;
  final String? dishId;
  final String? title;
  final double? grams;
  final double? portions;
  final double? portionG;
  final bool isMl;
  final Macros? per100;
  final Macros total;
  final String? statusMarkId;
  final String? batchId;
  final double? stockShort;
  final bool isPackNeeded;

  const MealEntry({
    required this.id,
    required this.date,
    required this.source,
    this.itemId,
    this.dishId,
    this.title,
    this.grams,
    this.portions,
    this.portionG,
    this.isMl = false,
    this.per100,
    required this.total,
    this.statusMarkId,
    this.batchId,
    this.stockShort,
    this.isPackNeeded = false,
  });

  factory MealEntry.fromJson(Map<String, dynamic> aJson) => MealEntry(
        id: aJson['id'] as String,
        date: parseDateWire(aJson['date']),
        source: MealSource.parse(aJson['source']),
        itemId: aJson['item_id'] as String?,
        dishId: aJson['dish_id'] as String?,
        title: aJson['title'] as String?,
        grams: parseDecimalOrNull(aJson['grams']),
        portions: parseDecimalOrNull(aJson['portions']),
        portionG: parseDecimalOrNull(aJson['portion_g']),
        isMl: aJson['is_ml'] as bool? ?? false,
        per100: Macros.fromJsonOrNull(aJson['per_100']),
        total: Macros.fromJson(aJson['total']),
        statusMarkId: aJson['status_mark_id'] as String?,
        batchId: aJson['batch_id'] as String?,
        stockShort: parseDecimalOrNull(aJson['stock_short']),
        isPackNeeded: aJson['is_pack_needed'] as bool? ?? false,
      );
}

class DayMeal
{
  final StatusMarkDto mark;
  final Macros total;
  final List<MealEntry> entries;

  const DayMeal({required this.mark, this.total = Macros.zero, this.entries = const []});

  MealKind get kind => MealKind.forTime(mark.startTs);

  bool isActiveAt(DateTime aMoment) => mark.isActiveAt(aMoment);

  factory DayMeal.fromJson(Map<String, dynamic> aJson) => DayMeal(
        mark: StatusMarkDto.fromJson(aJson['mark'] as Map<String, dynamic>),
        total: Macros.fromJson(aJson['total']),
        entries: _entries(aJson['entries']),
      );
}

List<MealEntry> _entries(Object? aJson) =>
    (aJson as List? ?? const []).map((aItem) => MealEntry.fromJson(aItem as Map<String, dynamic>)).toList();

enum GoalMode
{
  lose,
  maintain,
  gain;

  static GoalMode parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => GoalMode.maintain);
}

enum NormKind
{
  adult,
  child,
  custom;

  static NormKind parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => NormKind.adult);
}

enum NormWarning
{
  deficitCapped('deficit_capped'),
  floorReached('floor_reached'),
  surplusCapped('surplus_capped'),
  surplusRaised('surplus_raised'),
  targetPassed('target_passed'),
  customBelowFloor('custom_below_floor'),
  customMacrosMismatch('custom_macros_mismatch');

  final String wire;

  const NormWarning(this.wire);

  static NormWarning? parse(Object? aValue)
  {
    for (final warning in values)
    {
      if (warning.wire == aValue)
      {
        return warning;
      }
    }
    return null;
  }
}

class NutritionNorm
{
  final Macros target;
  final NormKind kind;
  final GoalMode mode;
  final int age;
  final double? maintenanceKcal;
  final double? bmr;
  final double? floorKcal;
  final double deltaKcal;
  final double? paceKg;
  final double? effectivePaceKg;
  final double? targetKg;
  final int? weeksToTarget;
  final ActivityLevel? activity;
  final double? weightKg;
  final int recentWorkouts;
  final bool isTrainingBoost;
  final List<NormWarning> warnings;

  const NutritionNorm({
    required this.target,
    this.kind = NormKind.adult,
    this.mode = GoalMode.maintain,
    this.age = 0,
    this.maintenanceKcal,
    this.bmr,
    this.floorKcal,
    this.deltaKcal = 0,
    this.paceKg,
    this.effectivePaceKg,
    this.targetKg,
    this.weeksToTarget,
    this.activity,
    this.weightKg,
    this.recentWorkouts = 0,
    this.isTrainingBoost = false,
    this.warnings = const [],
  });

  factory NutritionNorm.fromJson(Map<String, dynamic> aJson) => NutritionNorm(
        target: Macros.fromJson(aJson['target']),
        kind: NormKind.parse(aJson['kind']),
        mode: GoalMode.parse(aJson['mode']),
        age: (aJson['age'] as num?)?.toInt() ?? 0,
        maintenanceKcal: parseDecimalOrNull(aJson['maintenance_kcal']),
        bmr: parseDecimalOrNull(aJson['bmr']),
        floorKcal: parseDecimalOrNull(aJson['floor_kcal']),
        deltaKcal: parseDecimal(aJson['delta_kcal']),
        paceKg: parseDecimalOrNull(aJson['pace_kg']),
        effectivePaceKg: parseDecimalOrNull(aJson['effective_pace_kg']),
        targetKg: parseDecimalOrNull(aJson['target_kg']),
        weeksToTarget: (aJson['weeks_to_target'] as num?)?.toInt(),
        activity: ActivityLevel.parse(aJson['activity']),
        weightKg: parseDecimalOrNull(aJson['weight_kg']),
        recentWorkouts: (aJson['recent_workouts'] as num?)?.toInt() ?? 0,
        isTrainingBoost: aJson['is_training_boost'] as bool? ?? false,
        warnings: (aJson['warnings'] as List? ?? const []).map(NormWarning.parse).whereType<NormWarning>().toList(),
      );

  static NutritionNorm? fromJsonOrNull(Object? aJson) => aJson is Map<String, dynamic> ? NutritionNorm.fromJson(aJson) : null;
}

List<NormGap> _gaps(Object? aJson) => (aJson as List? ?? const []).map(NormGap.parse).whereType<NormGap>().toList();

class NutritionDay
{
  final String? personId;
  final bool canEdit;
  final DateTime date;
  final Macros total;
  final List<DayMeal> meals;
  final List<MealEntry> unlinked;
  final Macros unlinkedTotal;
  final NutritionNorm? norm;
  final List<NormGap> normGaps;
  final double workoutKcal;

  const NutritionDay({
    this.personId,
    this.canEdit = true,
    required this.date,
    this.total = Macros.zero,
    this.meals = const [],
    this.unlinked = const [],
    this.unlinkedTotal = Macros.zero,
    this.norm,
    this.normGaps = const [],
    this.workoutKcal = 0,
  });

  factory NutritionDay.fromJson(Map<String, dynamic> aJson) => NutritionDay(
        personId: aJson['person_id'] as String?,
        canEdit: aJson['can_edit'] as bool? ?? true,
        date: parseDateWire(aJson['date']),
        total: Macros.fromJson(aJson['total']),
        meals: (aJson['meals'] as List? ?? const [])
            .map((aItem) => DayMeal.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        unlinked: _entries(aJson['unlinked']),
        unlinkedTotal: Macros.fromJson(aJson['unlinked_total']),
        norm: NutritionNorm.fromJsonOrNull(aJson['norm']),
        normGaps: _gaps(aJson['norm_gaps']),
        workoutKcal: parseDecimal(aJson['workout_kcal']),
      );

  bool get isEmpty => meals.every((aMeal) => aMeal.entries.isEmpty) && unlinked.isEmpty;

  DayMeal? mealById(String? aMarkId) => meals.where((aMeal) => aMeal.mark.id == aMarkId).firstOrNull;

  DayMeal? activeMeal(DateTime aMoment) => meals.where((aMeal) => aMeal.isActiveAt(aMoment)).firstOrNull;
}

class NutritionGoal
{
  final GoalMode mode;
  final double? paceKg;
  final double? targetKg;
  final bool isCustom;
  final Macros? custom;
  final bool isChild;
  final NutritionNorm? norm;
  final List<NormGap> normGaps;

  const NutritionGoal({
    this.mode = GoalMode.maintain,
    this.paceKg,
    this.targetKg,
    this.isCustom = false,
    this.custom,
    this.isChild = false,
    this.norm,
    this.normGaps = const [],
  });

  factory NutritionGoal.fromJson(Map<String, dynamic> aJson) => NutritionGoal(
        mode: GoalMode.parse(aJson['mode']),
        paceKg: parseDecimalOrNull(aJson['pace_kg']),
        targetKg: parseDecimalOrNull(aJson['target_kg']),
        isCustom: aJson['is_custom'] as bool? ?? false,
        custom: Macros.fromJsonOrNull(aJson['custom']),
        isChild: aJson['is_child'] as bool? ?? false,
        norm: NutritionNorm.fromJsonOrNull(aJson['norm']),
        normGaps: _gaps(aJson['norm_gaps']),
      );
}

class GoalDraft
{
  final GoalMode mode;
  final double? paceKg;
  final double? targetKg;
  final bool isCustom;
  final Macros? custom;

  const GoalDraft({this.mode = GoalMode.maintain, this.paceKg, this.targetKg, this.isCustom = false, this.custom});

  factory GoalDraft.of(NutritionGoal aGoal) => GoalDraft(
        mode: aGoal.mode,
        paceKg: aGoal.paceKg,
        targetKg: aGoal.targetKg,
        isCustom: aGoal.isCustom,
        custom: aGoal.custom,
      );

  GoalDraft copyWith({GoalMode? mode, double? paceKg, double? targetKg, bool? isCustom, Macros? custom, bool isTargetCleared = false}) => GoalDraft(
        mode: mode ?? this.mode,
        paceKg: paceKg ?? this.paceKg,
        targetKg: isTargetCleared ? null : targetKg ?? this.targetKg,
        isCustom: isCustom ?? this.isCustom,
        custom: custom ?? this.custom,
      );

  Map<String, dynamic> toJson()
  {
    final custom = this.custom;
    return {
      'mode': mode.name,
      if (mode != GoalMode.maintain && paceKg != null) 'pace_kg': paceKg.toString(),
      if (mode != GoalMode.maintain && targetKg != null) 'target_kg': targetKg.toString(),
      'is_custom': isCustom,
      if (custom != null)
        'custom': {
          'kcal': custom.kcal.round().toString(),
          'prot': custom.prot.round().toString(),
          'fat': custom.fat.round().toString(),
          'carb': custom.carb.round().toString(),
        },
    };
  }
}

class PersonNorm
{
  final bool isChild;
  final NutritionNorm? norm;
  final List<NormGap> normGaps;
  final Macros eaten;

  const PersonNorm({this.isChild = false, this.norm, this.normGaps = const [], this.eaten = Macros.zero});

  factory PersonNorm.fromJson(Map<String, dynamic> aJson) => PersonNorm(
        isChild: aJson['is_child'] as bool? ?? false,
        norm: NutritionNorm.fromJsonOrNull(aJson['norm']),
        normGaps: _gaps(aJson['norm_gaps']),
        eaten: Macros.fromJson(aJson['eaten']),
      );
}

class CopyResult
{
  final int copied;
  final DateTime? sourceStartTs;

  const CopyResult({this.copied = 0, this.sourceStartTs});

  factory CopyResult.fromJson(Map<String, dynamic> aJson) => CopyResult(
        copied: (aJson['copied'] as num?)?.toInt() ?? 0,
        sourceStartTs: parseTsOrNull(aJson['source_start_ts']),
      );
}

class RecentFood
{
  final MealSource source;
  final String? itemId;
  final String? dishId;
  final String title;
  final double? grams;
  final double? portions;
  final bool isMl;
  final Macros? per100;

  const RecentFood({
    required this.source,
    this.itemId,
    this.dishId,
    required this.title,
    this.grams,
    this.portions,
    this.isMl = false,
    this.per100,
  });

  factory RecentFood.fromJson(Map<String, dynamic> aJson) => RecentFood(
        source: MealSource.parse(aJson['source']),
        itemId: aJson['item_id'] as String?,
        dishId: aJson['dish_id'] as String?,
        title: aJson['title'] as String? ?? '',
        grams: parseDecimalOrNull(aJson['grams']),
        portions: parseDecimalOrNull(aJson['portions']),
        isMl: aJson['is_ml'] as bool? ?? false,
        per100: Macros.fromJsonOrNull(aJson['per_100']),
      );
}
