import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';

String exerciseName(String? aCode, String aName)
{
  if (aCode == null)
  {
    return aName;
  }
  final key = 'exercises.catalog.$aCode';
  final text = key.tr();
  return text == key ? aName : text;
}

String exerciseDisplayName(DictExDto aExercise) => exerciseName(aExercise.code, aExercise.name);

String weekdayShort(BuildContext aContext, int aWeekday)
{
  final monday = DateTime(2024, 1, 1);
  return DateFormat.E(aContext.locale.toLanguageTag()).format(monday.add(Duration(days: aWeekday - 1)));
}

String formatClock(int aSeconds)
{
  final minutes = aSeconds ~/ 60;
  final seconds = aSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String formatSpan(Duration aDuration)
{
  final hours = aDuration.inHours;
  final minutes = aDuration.inMinutes % 60;
  return hours > 0 ? 'training.span_hm'.tr(args: ['$hours', '$minutes']) : 'training.span_m'.tr(args: ['$minutes']);
}

String formatWeight(BuildContext aContext, double aValue) =>
    '${NumberFormat('#,##0.##', aContext.locale.toLanguageTag()).format(aValue)} ${'metrics.unit_kg'.tr()}';

String formatNumber(BuildContext aContext, double aValue) => NumberFormat('#,##0.##', aContext.locale.toLanguageTag()).format(aValue);

String describeTarget(BuildContext aContext, {required int aSets, int? aRepsMin, int? aRepsMax, int? aDurationSec, double? aWeight, int? aRestSec})
{
  final reps = switch ((aRepsMin, aRepsMax))
  {
    (final int min, final int max) when min != max => '$min–$max',
    (final int min, _) => '$min',
    (_, final int max) => '$max',
    _ => null,
  };
  final volume = [
    if (reps != null) '$aSets × $reps' else if (aDurationSec != null) '$aSets × ${formatClock(aDurationSec)}' else 'training.sets_count'.tr(args: ['$aSets']),
    if (aWeight != null && aWeight > 0) formatWeight(aContext, aWeight),
    if (aRestSec != null && aRestSec > 0) 'training.rest_short'.tr(args: [formatClock(aRestSec)]),
  ];
  return volume.join(', ');
}

String describeSets(BuildContext aContext, List<SessionSet> aSets)
{
  return aSets
      .map((aSet)
      {
        if (aSet.durationSec != null && aSet.reps == null)
        {
          return formatClock(aSet.durationSec!);
        }
        final weight = aSet.weightKg;
        final reps = aSet.reps ?? 0;
        return weight == null || weight == 0 ? '$reps' : '${formatNumber(aContext, weight)}×$reps';
      })
      .join(', ');
}

String plannedDateLabel(BuildContext aContext, DateTime aDate)
{
  final today = DateUtils.dateOnly(DateTime.now());
  final date = DateUtils.dateOnly(aDate);
  final days = date.difference(today).inDays;
  if (days == 0)
  {
    return 'training.today'.tr();
  }
  if (days == 1)
  {
    return 'training.tomorrow'.tr();
  }
  return DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(date);
}
