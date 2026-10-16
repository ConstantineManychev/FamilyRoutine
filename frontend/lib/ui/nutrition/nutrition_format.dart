import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../routine/routine_style.dart';

final StateProvider<int> nutritionRevisionProv = StateProvider<int>((aRef) => 0);

void notifyNutritionChanged(WidgetRef aRef)
{
  aRef.read(nutritionRevisionProv.notifier).state++;
  aRef.read(routineRevisionProv.notifier).state++;
}

String mealLabel(MealSlot aMeal) => 'nutrition.meal_${aMeal.name}'.tr();

IconData mealIcon(MealSlot aMeal)
{
  return switch (aMeal)
  {
    MealSlot.breakfast => AppIcons.sunrise,
    MealSlot.lunch => AppIcons.soup,
    MealSlot.dinner => AppIcons.sunset,
    MealSlot.snack => AppIcons.cookie,
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

String normGapText(List<NormGap> aGaps)
{
  if (aGaps.contains(NormGap.child))
  {
    return 'nutrition.norm_child'.tr();
  }
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
