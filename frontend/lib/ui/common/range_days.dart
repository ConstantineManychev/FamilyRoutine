import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'app_theme.dart';

const List<int> rangeDayOptions = [1, 3, 7, 14, 31];

DateTime _dayOf(DateTime aValue) => DateTime(aValue.year, aValue.month, aValue.day);

DateTime rangeFirstDay(DateTime aLastDay, int aDays) => _dayOf(DateTime(aLastDay.year, aLastDay.month, aLastDay.day - aDays + 1));

double rangeContentWidth(double aViewport, int aDays, double aMinDayWidth) => math.max(aViewport, aDays * aMinDayWidth);

String rangeTitle(BuildContext aContext, DateTime aLastDay, int aDays)
{
  final locale = aContext.locale.toLanguageTag();
  final today = _dayOf(DateTime.now());
  final last = _dayOf(aLastDay);
  if (aDays == 1)
  {
    return last == today ? 'routine.today'.tr() : DateFormat.MMMd(locale).format(last);
  }
  final first = rangeFirstDay(last, aDays);
  return '${DateFormat.MMMd(locale).format(first)} – ${DateFormat.MMMd(locale).format(last)}';
}

class RangeDaysBar extends StatelessWidget
{
  final DateTime lastDay;
  final int days;
  final DateTime? maxDay;
  final ValueChanged<DateTime> onShift;
  final ValueChanged<int> onDays;
  final String keyPrefix;

  const RangeDaysBar({
    super.key,
    required this.lastDay,
    required this.days,
    required this.onShift,
    required this.onDays,
    required this.keyPrefix,
    this.maxDay,
  });

  DateTime _moved(int aDirection) => _dayOf(DateTime(lastDay.year, lastDay.month, lastDay.day + aDirection * days));

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final today = _dayOf(DateTime.now());
    final limit = maxDay ?? today;
    final next = _moved(1);
    final canForward = _dayOf(lastDay).isBefore(limit);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              key: ValueKey('$keyPrefix.prev'),
              tooltip: 'range.prev'.tr(),
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.chevronLeft, size: 18),
              onPressed: () => onShift(_moved(-1)),
            ),
            Expanded(
              child: Text(
                rangeTitle(aContext, lastDay, days),
                key: ValueKey('$keyPrefix.title'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary),
              ),
            ),
            IconButton(
              key: ValueKey('$keyPrefix.next'),
              tooltip: 'range.next'.tr(),
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.chevronRight, size: 18),
              onPressed: canForward ? () => onShift(next.isAfter(limit) ? limit : next) : null,
            ),
            if (!_dayOf(lastDay).isAtSameMomentAs(today))
              TextButton(
                key: ValueKey('$keyPrefix.today'),
                onPressed: () => onShift(today),
                child: Text('routine.today'.tr()),
              ),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final option in rangeDayOptions)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    key: ValueKey('$keyPrefix.days.$option'),
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    label: Text('range.days'.plural(option)),
                    selected: days == option,
                    onSelected: (_) => onDays(option),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
