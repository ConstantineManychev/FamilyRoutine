import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'nutrition_format.dart';

String dishSubtitle(BuildContext aContext, Dish aDish) => [
      per100Line(aContext, aDish.per100),
      if (aDish.portionG != null) 'nutrition.portion_is'.tr(args: [formatGrams(aContext, aDish.portionG!)]),
    ].join(' · ');

class DishesScreen extends ConsumerStatefulWidget
{
  const DishesScreen({super.key});

  @override
  ConsumerState<DishesScreen> createState() => _DishesScreenState();
}

class _DishesScreenState extends ConsumerState<DishesScreen>
{
  List<Dish>? _dishes;
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
      final dishes = await ref.read(apiProv).getDishes();
      if (mounted)
      {
        setState(()
        {
          _dishes = dishes;
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

  Widget _list(BuildContext aContext, String aQuery)
  {
    final dishes = _dishes;
    if (_error != null)
    {
      return ErrorRetry(error: _error!, onRetry: _load);
    }
    if (dishes == null)
    {
      return const Center(child: CircularProgressIndicator());
    }
    final palette = aContext.palette;
    final visible = dishes.where((aDish) => aQuery.isEmpty || aDish.name.toLowerCase().contains(aQuery)).toList();
    if (visible.isEmpty)
    {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            dishes.isEmpty ? 'nutrition.no_dishes_hint'.tr() : 'nutrition.nothing_found'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.inkMuted),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: fabClearance),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, aIndex)
        {
          final dish = visible[aIndex];
          return ListTile(
            onTap: () => _open('/app/dishes/${dish.id}'),
            leading: Icon(AppIcons.cookingPot, color: palette.inkSecondary),
            title: Text(dish.name),
            subtitle: Text(
              [
                dishSubtitle(aContext, dish),
                if (dish.ownerName != null) dish.ownerName!,
                if (dish.missingCount > 0) 'nutrition.missing_count'.plural(dish.missingCount),
              ].join(' · '),
            ),
            trailing: dish.isShared && dish.isEditable
                ? Tooltip(message: 'nutrition.shared'.tr(), child: Icon(AppIcons.users, size: 18, color: palette.inkMuted))
                : null,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    return ListPage(
      title: 'nutrition.dishes'.tr(),
      onAdd: () => _open('/app/dishes/new'),
      addTooltip: 'nutrition.new_dish'.tr(),
      searchHint: 'nutrition.search_dish'.tr(),
      builder: _list,
    );
  }
}
