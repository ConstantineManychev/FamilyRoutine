import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/person_switcher.dart';
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
  final Map<String?, NutritionDay> _days = {};
  final Map<String?, Object> _errors = {};
  String? _personId;

  @override
  void initState()
  {
    super.initState();
    _load(null);
  }

  Future<void> _load(String? aPersonId) async
  {
    try
    {
      final day = await ref.read(apiProv).getNutritionDay(dayOnly(DateTime.now()), aPersonId: aPersonId);
      if (mounted)
      {
        setState(()
        {
          _days[aPersonId] = day;
          _errors.remove(aPersonId);
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _errors[aPersonId] = aError);
      }
    }
  }

  void _reloadAll()
  {
    final shown = _personId;
    setState(()
    {
      _days.removeWhere((aKey, _) => aKey != shown);
      _errors.clear();
    });
    _load(shown);
  }

  void _select(PersonRef aPerson)
  {
    final personId = personQuery(aPerson);
    setState(() => _personId = personId);
    if (!_days.containsKey(personId))
    {
      _load(personId);
    }
  }

  Future<void> _open(String aPath) async
  {
    await context.push(aPath);
    _reloadAll();
  }

  Widget _buildContent(BuildContext aContext, NutritionDay? aDay, Object? aError, String? aPersonId)
  {
    final palette = aContext.palette;
    if (aError != null)
    {
      return ErrorRetry(error: aError, onRetry: () => _load(aPersonId));
    }
    if (aDay == null)
    {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    final eaten = aDay.meals.where((aMeal) => aMeal.entries.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NutritionSummary(
            day: aDay,
            isCompact: true,
            onOpenGoal: aDay.canEdit ? () => _open(goalPathFor(aPersonId)) : null,
          ),
          if (eaten.isEmpty)
            Text('nutrition.today_empty'.tr(), style: TextStyle(color: palette.inkMuted))
          else
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                for (final meal in eaten)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(mealIcon(meal.kind), size: 14, color: palette.inkSecondary),
                      const SizedBox(width: 4),
                      Text(
                        '${mealTitle(aContext, meal)} · ${formatKcal(aContext, meal.total.kcal)}',
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

  @override
  Widget build(BuildContext aContext)
  {
    ref.listen<int>(nutritionRevisionProv, (_, __) => _reloadAll());
    final people = ref.watch(peopleProv).valueOrNull ?? const <PersonRef>[];
    final personId = _personId;
    final index = people.indexWhere((aPerson) => personQuery(aPerson) == personId);
    final day = _days[personId];
    final canEdit = day?.canEdit ?? (index < 0 || people[index].canEdit);
    final content = _buildContent(aContext, day, _errors[personId], personId);

    return BlockCard(
      title: 'nutrition.today_block'.tr(),
      onAdd: canEdit ? () => _open(addFoodPath(dayOnly(DateTime.now()), aPersonId: personId)) : null,
      addTooltip: 'nutrition.add_food'.tr(),
      onExpand: () => _open(diaryPath(aPersonId: personId)),
      child: index < 0
          ? content
          : PersonSwipe(
              people: people,
              index: index,
              onChanged: (aIndex) => _select(people[aIndex]),
              child: content,
            ),
    );
  }
}
