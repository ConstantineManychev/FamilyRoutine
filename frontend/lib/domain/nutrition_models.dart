import 'finance_models.dart';
import 'planner_models.dart';
import 'profile_models.dart';

enum MealSlot
{
  breakfast,
  lunch,
  dinner,
  snack;

  static MealSlot parse(Object? aValue) => values.firstWhere((aItem) => aItem.name == aValue, orElse: () => MealSlot.snack);

  static MealSlot forHour(int aHour)
  {
    if (aHour < 11)
    {
      return MealSlot.breakfast;
    }
    if (aHour < 16)
    {
      return MealSlot.lunch;
    }
    if (aHour < 18)
    {
      return MealSlot.snack;
    }
    return MealSlot.dinner;
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
  activity,
  child;

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
  final MealSlot meal;
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

  const MealEntry({
    required this.id,
    required this.date,
    required this.meal,
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
  });

  factory MealEntry.fromJson(Map<String, dynamic> aJson) => MealEntry(
        id: aJson['id'] as String,
        date: parseDateWire(aJson['date']),
        meal: MealSlot.parse(aJson['meal']),
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
      );
}

class MealGroup
{
  final MealSlot meal;
  final Macros total;
  final List<MealEntry> entries;

  const MealGroup({required this.meal, this.total = Macros.zero, this.entries = const []});

  factory MealGroup.fromJson(Map<String, dynamic> aJson) => MealGroup(
        meal: MealSlot.parse(aJson['meal']),
        total: Macros.fromJson(aJson['total']),
        entries: (aJson['entries'] as List? ?? const [])
            .map((aItem) => MealEntry.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class NutritionNorm
{
  final Macros target;
  final double bmr;
  final ActivityLevel? activity;
  final double weightKg;

  const NutritionNorm({required this.target, required this.bmr, this.activity, required this.weightKg});

  factory NutritionNorm.fromJson(Map<String, dynamic> aJson) => NutritionNorm(
        target: Macros.fromJson(aJson['target']),
        bmr: parseDecimal(aJson['bmr']),
        activity: ActivityLevel.parse(aJson['activity']),
        weightKg: parseDecimal(aJson['weight_kg']),
      );
}

class NutritionDay
{
  final DateTime date;
  final Macros total;
  final List<MealGroup> meals;
  final NutritionNorm? norm;
  final List<NormGap> normGaps;
  final double workoutKcal;

  const NutritionDay({
    required this.date,
    this.total = Macros.zero,
    this.meals = const [],
    this.norm,
    this.normGaps = const [],
    this.workoutKcal = 0,
  });

  factory NutritionDay.fromJson(Map<String, dynamic> aJson) => NutritionDay(
        date: parseDateWire(aJson['date']),
        total: Macros.fromJson(aJson['total']),
        meals: (aJson['meals'] as List? ?? const [])
            .map((aItem) => MealGroup.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        norm: aJson['norm'] is Map<String, dynamic> ? NutritionNorm.fromJson(aJson['norm'] as Map<String, dynamic>) : null,
        normGaps: (aJson['norm_gaps'] as List? ?? const []).map(NormGap.parse).whereType<NormGap>().toList(),
        workoutKcal: parseDecimal(aJson['workout_kcal']),
      );

  MealGroup group(MealSlot aMeal) => meals.firstWhere((aItem) => aItem.meal == aMeal, orElse: () => MealGroup(meal: aMeal));

  bool get isEmpty => meals.every((aGroup) => aGroup.entries.isEmpty);
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
