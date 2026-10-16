import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/api_svc.dart';
import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../routine/routine_style.dart';
import 'nutrition_format.dart';

const List<int> mealDurations = [15, 30, 60];
const int defaultMealMinutes = 30;
const int _pastDayHour = 12;

class MealTarget
{
  final String? markId;
  final DateTime start;
  final int minutes;

  const MealTarget.existing(String this.markId, this.start) : minutes = defaultMealMinutes;

  const MealTarget.fresh(this.start, {this.minutes = defaultMealMinutes}) : markId = null;

  bool get isNew => markId == null;

  DateTime get end => start.add(Duration(minutes: minutes));

  MealKind get kind => MealKind.forTime(start);
}

MealTarget defaultMealTarget(DateTime aDate, List<DayMeal> aMeals, {String? aMarkId, DateTime? aNow})
{
  final now = aNow ?? DateTime.now();
  final preferred = aMeals.where((aMeal) => aMeal.mark.id == aMarkId).firstOrNull;
  if (preferred != null)
  {
    return MealTarget.existing(preferred.mark.id, preferred.mark.startTs);
  }
  final isToday = dayOnly(aDate) == dayOnly(now);
  if (isToday)
  {
    final active = aMeals.where((aMeal) => aMeal.isActiveAt(now)).firstOrNull;
    if (active != null)
    {
      return MealTarget.existing(active.mark.id, active.mark.startTs);
    }
    return MealTarget.fresh(DateTime(now.year, now.month, now.day, now.hour, now.minute));
  }
  final last = aMeals.lastOrNull;
  if (last != null)
  {
    return MealTarget.existing(last.mark.id, last.mark.startTs);
  }
  return MealTarget.fresh(DateTime(aDate.year, aDate.month, aDate.day, _pastDayHour));
}

Future<String> ensureMealBlock(ApiSvc aApi, MealTarget aTarget) async
{
  final markId = aTarget.markId;
  if (markId != null)
  {
    return markId;
  }
  final mark = await aApi.createMark(RoutineStatus.meal, aStartTs: aTarget.start, aEndTs: aTarget.end);
  return mark.id;
}

class MealTargetPicker extends StatelessWidget
{
  final DateTime date;
  final List<DayMeal> meals;
  final MealTarget value;
  final ValueChanged<MealTarget> onChanged;
  final bool isEnabled;

  const MealTargetPicker({
    super.key,
    required this.date,
    required this.meals,
    required this.value,
    required this.onChanged,
    this.isEnabled = true,
  });

  Future<void> _pickStart(BuildContext aContext) async
  {
    final picked = await showTimePicker(context: aContext, initialTime: TimeOfDay.fromDateTime(value.start));
    if (picked != null)
    {
      onChanged(MealTarget.fresh(
        DateTime(date.year, date.month, date.day, picked.hour, picked.minute),
        minutes: value.minutes,
      ));
    }
  }

  MealTarget _freshDefault()
  {
    final now = DateTime.now();
    final isToday = dayOnly(date) == dayOnly(now);
    return MealTarget.fresh(isToday
        ? DateTime(now.year, now.month, now.day, now.hour, now.minute)
        : DateTime(date.year, date.month, date.day, _pastDayHour));
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('nutrition.meal'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final meal in meals)
              ChoiceChip(
                key: ValueKey('meal.target.${meal.mark.id}'),
                showCheckmark: false,
                avatar: Icon(mealIcon(meal.kind), size: 16),
                label: Text(mealTitle(aContext, meal)),
                selected: value.markId == meal.mark.id,
                onSelected: isEnabled ? (_) => onChanged(MealTarget.existing(meal.mark.id, meal.mark.startTs)) : null,
              ),
            ChoiceChip(
              key: const ValueKey('meal.target.new'),
              showCheckmark: false,
              avatar: const Icon(AppIcons.plus, size: 16),
              label: Text('nutrition.new_meal'.tr()),
              selected: value.isNew,
              onSelected: isEnabled ? (_) => onChanged(value.isNew ? value : _freshDefault()) : null,
            ),
          ],
        ),
        if (value.isNew) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ActionChip(
                key: const ValueKey('meal.target.start'),
                avatar: const Icon(AppIcons.clock, size: 16),
                label: Text('routine.start_at'.tr(args: [formatClock(aContext, value.start)])),
                onPressed: isEnabled ? () => _pickStart(aContext) : null,
              ),
              for (final minutes in mealDurations)
                ChoiceChip(
                  showCheckmark: false,
                  label: Text(formatDuration(Duration(minutes: minutes))),
                  selected: value.minutes == minutes,
                  onSelected: isEnabled ? (_) => onChanged(MealTarget.fresh(value.start, minutes: minutes)) : null,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'nutrition.new_meal_hint'.tr(args: [
              mealLabel(value.kind),
              '${formatClock(aContext, value.start)}–${formatClock(aContext, value.end)}',
            ]),
            style: TextStyle(fontSize: 12, color: palette.inkMuted),
          ),
        ],
      ],
    );
  }
}
