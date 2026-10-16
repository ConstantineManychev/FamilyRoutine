import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'nutrition_diary_screen.dart';
import 'nutrition_format.dart';
import 'nutrition_summary.dart';

class NutritionTodayBlock extends ConsumerStatefulWidget
{
  const NutritionTodayBlock({super.key});

  @override
  ConsumerState<NutritionTodayBlock> createState() => _NutritionTodayBlockState();
}

class _NutritionTodayBlockState extends ConsumerState<NutritionTodayBlock>
{
  NutritionDay? _day;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    try
    {
      final day = await ref.read(apiProv).getNutritionDay(dayOnly(DateTime.now()));
      if (mounted)
      {
        setState(()
        {
          _day = day;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  Future<void> _open(String aPath) async
  {
    await context.push(aPath);
    await _load();
  }

  @override
  Widget build(BuildContext aContext)
  {
    ref.listen<int>(nutritionRevisionProv, (_, __) => _load());
    final day = _day;
    final palette = aContext.palette;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (day == null)
    {
      content = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else
    {
      final eaten = MealSlot.values.map(day.group).where((aGroup) => aGroup.entries.isNotEmpty).toList();
      content = Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NutritionSummary(day: day, isCompact: true),
            if (eaten.isEmpty)
              Text('nutrition.today_empty'.tr(), style: TextStyle(color: palette.inkMuted))
            else
              Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  for (final group in eaten)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(mealIcon(group.meal), size: 14, color: palette.inkSecondary),
                        const SizedBox(width: 4),
                        Text(
                          '${mealLabel(group.meal)} ${formatKcal(aContext, group.total.kcal)}',
                          style: TextStyle(color: palette.inkSecondary),
                        ),
                      ],
                    ),
                ],
              ),
          ],
        ),
      );
    }

    final now = DateTime.now();
    return BlockCard(
      title: 'nutrition.today_block'.tr(),
      onAdd: () => _open(addFoodPath(dayOnly(now), MealSlot.forHour(now.hour))),
      addTooltip: 'nutrition.add_food'.tr(),
      onExpand: () => _open('/app/nutrition'),
      child: content,
    );
  }
}
