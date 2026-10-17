import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../routine/routine_style.dart';
import '../stock/stock_format.dart';

final StateProvider<int> nutritionRevisionProv = StateProvider<int>((aRef) => 0);

void notifyNutritionChanged(WidgetRef aRef)
{
  aRef.read(nutritionRevisionProv.notifier).state++;
  aRef.read(routineRevisionProv.notifier).state++;
  aRef.read(stockRevisionProv.notifier).state++;
}

String mealLabel(MealKind aKind) => switch (aKind)
{
  MealKind.breakfast => 'nutrition.meal_breakfast'.tr(),
  MealKind.secondBreakfast => 'nutrition.meal_second_breakfast'.tr(),
  MealKind.lunch => 'nutrition.meal_lunch'.tr(),
  MealKind.afternoonSnack => 'nutrition.meal_afternoon_snack'.tr(),
  MealKind.dinner => 'nutrition.meal_dinner'.tr(),
  MealKind.nightSnack => 'nutrition.meal_night_snack'.tr(),
};

IconData mealIcon(MealKind aKind) => switch (aKind)
{
  MealKind.breakfast => AppIcons.sunrise,
  MealKind.secondBreakfast => AppIcons.coffee,
  MealKind.lunch => AppIcons.soup,
  MealKind.afternoonSnack => AppIcons.cookie,
  MealKind.dinner => AppIcons.sunset,
  MealKind.nightSnack => AppIcons.moon,
};

String mealTitle(BuildContext aContext, DayMeal aMeal) => '${mealLabel(aMeal.kind)} · ${formatClock(aContext, aMeal.mark.startTs)}';

String goalModeLabel(GoalMode aMode) => 'goal.mode_${aMode.name}'.tr();

String paceText(BuildContext aContext, double aPace) => 'goal.pace_value'.tr(args: [formatAmount(aContext, aPace, aDigits: 2)]);

String signedKcal(BuildContext aContext, double aValue)
{
  final sign = aValue > 0 ? '+' : (aValue < 0 ? '−' : '');
  return '$sign${formatAmount(aContext, aValue.abs(), aDigits: 0)}';
}

String normHeadline(BuildContext aContext, NutritionNorm aNorm)
{
  return switch (aNorm.kind)
  {
    NormKind.child => 'goal.child_norm'.tr(args: ['${aNorm.age}']),
    NormKind.custom => 'goal.custom_norm'.tr(),
    NormKind.adult when aNorm.mode == GoalMode.maintain => goalModeLabel(aNorm.mode),
    NormKind.adult => 'goal.mode_line'.tr(args: [
        goalModeLabel(aNorm.mode),
        signedKcal(aContext, aNorm.deltaKcal),
        paceText(aContext, aNorm.effectivePaceKg ?? 0),
      ]),
  };
}

String normWarningText(BuildContext aContext, NormWarning aWarning, NutritionNorm aNorm)
{
  final floor = formatAmount(aContext, aNorm.floorKcal ?? 0, aDigits: 0);
  final pace = paceText(aContext, aNorm.effectivePaceKg ?? 0);
  return switch (aWarning)
  {
    NormWarning.deficitCapped => 'goal.warn_deficit_capped'.tr(args: [pace]),
    NormWarning.floorReached => 'goal.warn_floor_reached'.tr(args: [floor, pace]),
    NormWarning.surplusCapped => 'goal.warn_surplus_capped'.tr(args: [pace]),
    NormWarning.surplusRaised => 'goal.warn_surplus_raised'.tr(args: [pace]),
    NormWarning.targetPassed => 'goal.warn_target_passed'.tr(),
    NormWarning.customBelowFloor => 'goal.warn_custom_below_floor'.tr(args: [floor]),
    NormWarning.customMacrosMismatch => 'goal.warn_custom_mismatch'.tr(),
  };
}

String formatAmount(BuildContext aContext, double aValue, {int aDigits = 1})
{
  final pattern = aDigits <= 0 ? '#,##0' : '#,##0.${'#' * aDigits}';
  return NumberFormat(pattern, aContext.locale.toLanguageTag()).format(aValue);
}

String formatKcal(BuildContext aContext, double aValue) => 'nutrition.kcal_value'.tr(args: [formatAmount(aContext, aValue, aDigits: 0)]);

String formatGrams(BuildContext aContext, double aValue, {bool aIsMl = false}) =>
    (aIsMl ? 'nutrition.ml_value' : 'nutrition.g_value').tr(args: [formatAmount(aContext, aValue)]);

String macrosLine(BuildContext aContext, Macros aMacros) => 'nutrition.macros_line'.tr(args: [
      formatAmount(aContext, aMacros.prot),
      formatAmount(aContext, aMacros.fat),
      formatAmount(aContext, aMacros.carb),
    ]);

String per100Line(BuildContext aContext, Macros aMacros, {bool aIsMl = false}) => (aIsMl ? 'nutrition.per_100ml' : 'nutrition.per_100g').tr(args: [
      formatAmount(aContext, aMacros.kcal, aDigits: 0),
      macrosLine(aContext, aMacros),
    ]);

String entryTitle(MealEntry aEntry) => aEntry.title ?? 'nutrition.quick_title'.tr();

String entryAmount(BuildContext aContext, MealEntry aEntry)
{
  final grams = aEntry.grams;
  if (grams == null)
  {
    return '';
  }
  final weight = formatGrams(aContext, grams, aIsMl: aEntry.isMl);
  final portions = aEntry.portions;
  if (portions == null)
  {
    return weight;
  }
  final count = formatAmount(aContext, portions, aDigits: 2);
  final unit = aEntry.source == MealSource.dish ? 'nutrition.portions_value' : 'nutrition.pieces_value';
  return '${unit.tr(args: [count])} · $weight';
}

String? entryStockNote(BuildContext aContext, MealEntry aEntry)
{
  final short = aEntry.stockShort;
  if (short != null && short > 0)
  {
    return 'stock.entry_short'.tr(args: [formatGrams(aContext, short, aIsMl: aEntry.isMl)]);
  }
  return aEntry.batchId == null ? null : 'stock.entry_batch'.tr();
}

String normGapText(List<NormGap> aGaps)
{
  final names = aGaps.map((aGap) => 'nutrition.gap_${aGap.name}'.tr()).join(', ');
  return 'nutrition.norm_missing'.tr(args: [names]);
}

double? parseAmountText(String aText)
{
  final text = aText.trim().replaceAll(',', '.').replaceAll(' ', '');
  return text.isEmpty ? null : double.tryParse(text);
}

String amountText(double? aValue)
{
  if (aValue == null)
  {
    return '';
  }
  if (aValue == aValue.roundToDouble())
  {
    return aValue.toStringAsFixed(0);
  }
  final text = aValue.toStringAsFixed(2);
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

DateTime dayOnly(DateTime aValue) => DateTime(aValue.year, aValue.month, aValue.day);

String dayTitle(BuildContext aContext, DateTime aDate)
{
  final today = dayOnly(DateTime.now());
  final diff = dayOnly(aDate).difference(today).inDays;
  final formatted = DateFormat.MMMMEEEEd(aContext.locale.toLanguageTag()).format(aDate);
  return switch (diff)
  {
    0 => '${'nutrition.today'.tr()}, $formatted',
    -1 => '${'nutrition.yesterday'.tr()}, $formatted',
    _ => formatted,
  };
}
