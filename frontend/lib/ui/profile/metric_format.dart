import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';

String metricName(BodyMetric aMetric) => 'metrics.${aMetric.wire}'.tr();

String metricGroupName(MetricGroup aGroup) => 'metrics.group_${aGroup.name}'.tr();

String metricUnit(BodyMetric aMetric) => switch (aMetric.unit)
{
  MetricUnit.cm => 'metrics.unit_cm'.tr(),
  MetricUnit.kg => 'metrics.unit_kg'.tr(),
  MetricUnit.percent => '%',
  MetricUnit.level => '',
};

String formatMetricNumber(BuildContext aContext, double aValue, {bool aIsSigned = false})
{
  final text = NumberFormat('#,##0.##', aContext.locale.toLanguageTag()).format(aValue.abs());
  if (!aIsSigned || aValue == 0)
  {
    return aValue < 0 ? '−$text' : text;
  }
  return aValue > 0 ? '+$text' : '−$text';
}

String formatMetric(BuildContext aContext, BodyMetric aMetric, double aValue, {bool aIsSigned = false})
{
  final number = formatMetricNumber(aContext, aValue, aIsSigned: aIsSigned);
  final unit = metricUnit(aMetric);
  if (unit.isEmpty)
  {
    return number;
  }
  return aMetric.unit == MetricUnit.percent ? '$number$unit' : '$number $unit';
}

double? parseMetricInput(String aText)
{
  final cleaned = aText.trim().replaceAll(' ', '').replaceAll(' ', '').replaceAll(',', '.');
  return cleaned.isEmpty ? null : double.tryParse(cleaned);
}

String formatMeasuredDate(BuildContext aContext, DateTime aTs) => DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(aTs);

String formatMeasuredTs(BuildContext aContext, DateTime aTs) =>
    DateFormat.yMMMd(aContext.locale.toLanguageTag()).add_Hm().format(aTs);
