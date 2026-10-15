import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import 'app_icons.dart';


String formatMoney(BuildContext aContext, double aAmount, String aCurrCode, {bool aIsSigned = false})
{
  final format = NumberFormat.simpleCurrency(locale: Localizations.localeOf(aContext).toLanguageTag(), name: aCurrCode, decimalDigits: 2);
  final text = format.format(aAmount.abs());

  if (aAmount < 0)
  {
    return '−$text';
  }

  return aIsSigned && aAmount > 0 ? '+$text' : text;
}

String formatCompact(BuildContext aContext, double aAmount)
{
  return NumberFormat.compact(locale: Localizations.localeOf(aContext).toLanguageTag()).format(aAmount);
}

double? parseAmountInput(String aText)
{
  final normalized = aText.replaceAll(RegExp(r'\s'), '').replaceAll(',', '.');
  final value = double.tryParse(normalized);

  if (value == null || !value.isFinite)
  {
    return null;
  }

  return (value * 100).roundToDouble() / 100;
}

String formatDateTime(BuildContext aContext, DateTime aTs)
{
  return DateFormat.yMMMd(Localizations.localeOf(aContext).toLanguageTag()).add_Hm().format(aTs);
}

String formatDate(BuildContext aContext, DateTime aTs)
{
  return DateFormat.yMMMd(Localizations.localeOf(aContext).toLanguageTag()).format(aTs);
}

String formatDay(BuildContext aContext, DateTime aTs)
{
  return DateFormat.yMMMMEEEEd(Localizations.localeOf(aContext).toLanguageTag()).format(aTs);
}

IconData categoryIcon(TxCategory? aCategory)
{
  return switch (aCategory)
  {
    TxCategory.groceries => AppIcons.shoppingCart,
    TxCategory.restaurants => AppIcons.utensils,
    TxCategory.transport => AppIcons.bus,
    TxCategory.fuel => AppIcons.fuel,
    TxCategory.shopping => AppIcons.shoppingBag,
    TxCategory.health => AppIcons.heartPulse,
    TxCategory.utilities => AppIcons.zap,
    TxCategory.entertainment => AppIcons.clapperboard,
    TxCategory.travel => AppIcons.plane,
    TxCategory.education => AppIcons.graduationCap,
    TxCategory.home => AppIcons.house,
    TxCategory.cash => AppIcons.banknote,
    TxCategory.transfer => AppIcons.arrowLeftRight,
    TxCategory.fees => AppIcons.receipt,
    TxCategory.income => AppIcons.trendingUp,
    TxCategory.other || null => AppIcons.circleDot,
  };
}

String categoryLabel(TxCategory? aCategory) => 'finance.cat.${aCategory?.name ?? 'none'}'.tr();
