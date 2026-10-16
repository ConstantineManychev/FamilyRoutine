import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'nutrition_format.dart';

const double _overLimit = 1.1;
const double _barHeight = 8;

class NutritionSummary extends StatelessWidget
{
  final NutritionDay day;
  final bool isCompact;
  final VoidCallback? onOpenGoal;

  const NutritionSummary({super.key, required this.day, this.isCompact = false, this.onOpenGoal});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final norm = day.norm;
    final total = day.total;
    final target = norm?.target;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _KcalHeadline(eaten: total.kcal, target: target?.kcal),
        const SizedBox(height: 12),
        _MacroBar(label: 'nutrition.kcal_short'.tr(), value: total.kcal, target: target?.kcal, unit: 'nutrition.kcal_unit'.tr(), digits: 0),
        _MacroBar(label: 'nutrition.prot'.tr(), value: total.prot, target: target?.prot, unit: 'nutrition.g_unit'.tr()),
        _MacroBar(label: 'nutrition.fat'.tr(), value: total.fat, target: target?.fat, unit: 'nutrition.g_unit'.tr()),
        _MacroBar(label: 'nutrition.carb'.tr(), value: total.carb, target: target?.carb, unit: 'nutrition.g_unit'.tr()),
        if (norm == null && day.normGaps.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(AppIcons.alertCircle, size: 16, color: palette.inkMuted),
              const SizedBox(width: 6),
              Expanded(child: Text(normGapText(day.normGaps), style: TextStyle(fontSize: 12, color: palette.inkSecondary))),
              TextButton(onPressed: () => aContext.push('/app/profile'), child: Text('nutrition.open_profile'.tr())),
            ],
          ),
        ],
        if (norm != null) ...[
          const SizedBox(height: 2),
          NormLine(norm: norm, onTap: onOpenGoal),
          if (!isCompact) ...[
            for (final warning in norm.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(normWarningText(aContext, warning, norm), style: TextStyle(fontSize: 12, color: palette.warning)),
              ),
            const SizedBox(height: 4),
            Text(normBasis(aContext, norm), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
          ],
        ],
        if (day.workoutKcal > 0 && !isCompact) ...[
          const SizedBox(height: 4),
          Text(
            'nutrition.workout_kcal'.tr(args: [formatAmount(aContext, day.workoutKcal, aDigits: 0)]),
            style: TextStyle(fontSize: 12, color: palette.inkMuted),
          ),
        ],
      ],
    );
  }
}

class _KcalHeadline extends StatelessWidget
{
  final double eaten;
  final double? target;

  const _KcalHeadline({required this.eaten, this.target});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final goal = target;
    final String note;
    Color noteColor = palette.inkSecondary;
    if (goal == null || goal <= 0)
    {
      note = 'nutrition.no_norm'.tr();
    }
    else if (eaten <= goal)
    {
      note = 'nutrition.left'.tr(args: [formatAmount(aContext, goal - eaten, aDigits: 0)]);
    }
    else
    {
      note = 'nutrition.over'.tr(args: [formatAmount(aContext, eaten - goal, aDigits: 0)]);
      noteColor = palette.warning;
    }

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 12,
      runSpacing: 4,
      children: [
        Text.rich(
          TextSpan(children: [
            TextSpan(
              text: formatAmount(aContext, eaten, aDigits: 0),
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: palette.inkPrimary),
            ),
            TextSpan(
              text: goal == null ? ' ${'nutrition.kcal_unit'.tr()}' : ' / ${formatAmount(aContext, goal, aDigits: 0)} ${'nutrition.kcal_unit'.tr()}',
              style: TextStyle(fontSize: 15, color: palette.inkSecondary),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(note, style: TextStyle(color: noteColor, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _MacroBar extends StatelessWidget
{
  final String label;
  final double value;
  final double? target;
  final String unit;
  final int digits;

  const _MacroBar({required this.label, required this.value, required this.target, required this.unit, this.digits = 1});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final goal = target;
    final ratio = goal == null || goal <= 0 ? null : value / goal;
    final isOver = ratio != null && ratio > _overLimit;
    final valueText = formatAmount(aContext, value, aDigits: digits);
    final text = goal == null ? '$valueText $unit' : '$valueText / ${formatAmount(aContext, goal, aDigits: 0)} $unit';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        label: '$label: $text',
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: TextStyle(color: palette.inkSecondary))),
                Text(text, style: TextStyle(fontWeight: FontWeight.w600, color: isOver ? palette.warning : palette.inkPrimary)),
              ],
            ),
            if (ratio != null) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(_barHeight / 2),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0, 1).toDouble(),
                  minHeight: _barHeight,
                  backgroundColor: palette.surfaceMuted,
                  color: isOver ? palette.warning : aContext.colors.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String normBasis(BuildContext aContext, NutritionNorm aNorm)
{
  final activity = 'nutrition.activity_${aNorm.activity?.wire ?? 'moderate'}'.tr();
  final maintenance = formatAmount(aContext, aNorm.maintenanceKcal ?? 0, aDigits: 0);
  return switch (aNorm.kind)
  {
    NormKind.child => aNorm.isTrainingBoost
        ? 'goal.child_basis_boost'.tr(args: [maintenance, activity, '${aNorm.recentWorkouts}'])
        : 'goal.child_basis'.tr(args: [maintenance, activity]),
    NormKind.custom when aNorm.maintenanceKcal == null => 'goal.custom_basis'.tr(),
    _ => 'nutrition.norm_basis'.tr(args: [
        maintenance,
        formatAmount(aContext, aNorm.bmr ?? 0, aDigits: 0),
        activity,
        formatAmount(aContext, aNorm.weightKg ?? 0),
      ]),
  };
}

class NormLine extends StatelessWidget
{
  final NutritionNorm norm;
  final VoidCallback? onTap;

  const NormLine({super.key, required this.norm, this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final tap = onTap;
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(AppIcons.slidersHorizontal, size: 14, color: palette.inkSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              normHeadline(aContext, norm),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: palette.inkSecondary),
            ),
          ),
          if (norm.warnings.isNotEmpty) Icon(AppIcons.alertCircle, size: 14, color: palette.warning),
          if (tap != null) Icon(AppIcons.chevronRight, size: 16, color: palette.inkMuted),
        ],
      ),
    );
    if (tap == null)
    {
      return line;
    }
    return Semantics(
      button: true,
      child: InkWell(key: const ValueKey('nutrition.norm_line'), borderRadius: BorderRadius.circular(6), onTap: tap, child: line),
    );
  }
}
