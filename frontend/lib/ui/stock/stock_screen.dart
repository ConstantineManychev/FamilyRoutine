import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../common/page_frames.dart';
import '../nutrition/nutrition_format.dart';
import 'stock_actions.dart';
import 'stock_format.dart';

const double _contentMaxWidth = 760;

class StockScreen extends ConsumerStatefulWidget
{
  const StockScreen({super.key});

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen>
{
  StockStoreRef? _store;
  StockData? _data;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    final store = _store;
    try
    {
      final data = await ref.read(apiProv).getStock(aStore: store);
      if (mounted && store == _store)
      {
        setState(()
        {
          _data = data;
          _store = data.store;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted && store == _store)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _selectStore(StockStoreRef aStore)
  {
    setState(()
    {
      _store = aStore;
      _data = null;
      _error = null;
    });
    _load();
  }

  Future<void> _makeActive(StockStoreRef aStore) async
  {
    try
    {
      await ref.read(apiProv).saveStockSettings(aStore.familyId);
      notifyStockChanged(ref);
      if (mounted)
      {
        showInfoSnack(context, 'stock.active_set'.tr(args: [storeLabel(aStore)]));
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  Widget _storeBar(BuildContext aContext, StockSettings? aSettings)
  {
    final palette = aContext.palette;
    final data = _data;
    final stores = aSettings?.stores ?? const <StockStore>[];
    final current = data?.store ?? _store;
    final isActive = data?.isActive ?? false;

    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (stores.length > 1 && current != null)
              DropdownButtonFormField<String>(
                key: ValueKey('stock.store.${current.familyId}'),
                initialValue: current.familyId ?? '',
                isExpanded: true,
                decoration: InputDecoration(labelText: 'stock.store'.tr(), border: const OutlineInputBorder(), isDense: true),
                items: [
                  for (final store in stores)
                    DropdownMenuItem(
                      value: store.ref.familyId ?? '',
                      child: Row(
                        children: [
                          Icon(store.ref.isPersonal ? AppIcons.user : AppIcons.users, size: 16),
                          const SizedBox(width: 8),
                          Flexible(child: Text(storeLabel(store.ref), overflow: TextOverflow.ellipsis)),
                          if (store.isActive) ...[
                            const SizedBox(width: 6),
                            Icon(AppIcons.checkCircle, size: 14, color: palette.positive),
                          ],
                        ],
                      ),
                    ),
                ],
                onChanged: (aValue)
                {
                  final store = stores.where((aStore) => (aStore.ref.familyId ?? '') == aValue).firstOrNull;
                  if (store != null)
                  {
                    _selectStore(store.ref);
                  }
                },
              )
            else if (current != null)
              Text(storeLabel(current), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    isActive ? 'stock.active_hint'.tr() : 'stock.inactive_hint'.tr(),
                    style: TextStyle(fontSize: 12, color: palette.inkMuted),
                  ),
                ),
                const SizedBox(width: 8),
                if (isActive)
                  Chip(
                    key: const ValueKey('stock.active'),
                    avatar: Icon(AppIcons.checkCircle, size: 16, color: palette.positive),
                    label: Text('stock.active'.tr()),
                  )
                else if (current != null)
                  OutlinedButton(
                    key: const ValueKey('stock.make_active'),
                    onPressed: () => _makeActive(current),
                    child: Text('stock.make_active'.tr()),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext aContext, StockStoreRef aStore)
  {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          key: const ValueKey('stock.add'),
          onPressed: () => addLotFlow(context, ref, aStore),
          icon: const Icon(AppIcons.plus, size: 18),
          label: Text('stock.add'.tr()),
        ),
        FilledButton.tonalIcon(
          key: const ValueKey('stock.cook'),
          onPressed: () => cookFlow(context, ref, aStore),
          icon: const Icon(AppIcons.cookingPot, size: 18),
          label: Text('stock.cook'.tr()),
        ),
        OutlinedButton.icon(
          key: const ValueKey('stock.history'),
          onPressed: () => context.push(stockHistoryPath(aStore)),
          icon: const Icon(AppIcons.history, size: 18),
          label: Text('stock.history'.tr()),
        ),
      ],
    );
  }

  Widget _lotMenu(StockLot aLot)
  {
    return PopupMenuButton<String>(
      key: ValueKey('stock.lot_menu.${aLot.id}'),
      tooltip: 'common.actions'.tr(),
      icon: const Icon(AppIcons.moreVertical, size: 18),
      onSelected: (aAction) => aAction == 'waste' ? wasteLotFlow(context, ref, aLot) : deleteLotFlow(context, ref, aLot),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'waste', child: Text('stock.waste'.tr())),
        if (aLot.isRemovable)
          PopupMenuItem(
            value: 'delete',
            child: Text(aLot.source == StockSource.cooked ? 'stock.uncook'.tr() : 'common.delete'.tr()),
          ),
      ],
    );
  }

  String _lotLine(BuildContext aContext, StockLot aLot)
  {
    final cost = aLot.leftCost;
    final currCode = aLot.currCode;
    return [
      DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aLot.acquiredTs),
      sourceLabel(aLot.source),
      'stock.left_of_total'.tr(args: [formatStockQty(aContext, aLot.leftQty, aLot.measure), formatStockQty(aContext, aLot.qty, aLot.measure)]),
      if (cost != null && currCode != null) formatMoney(aContext, cost, currCode),
    ].join(' · ');
  }

  Widget _lotTile(BuildContext aContext, StockLot aLot)
  {
    return ListTile(
      key: ValueKey('stock.lot.${aLot.id}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: Icon(sourceIcon(aLot.source), size: 18, color: aContext.palette.inkMuted),
      title: Text(_lotLine(aContext, aLot), style: const TextStyle(fontSize: 13)),
      trailing: _lotMenu(aLot),
    );
  }

  Widget _itemGroup(BuildContext aContext, StockGroup aGroup)
  {
    final palette = aContext.palette;
    final first = aGroup.first;
    final per100 = first.per100;
    return ExpansionTile(
      key: ValueKey('stock.group.${aGroup.key}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(aGroup.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          formatStockQty(aContext, aGroup.leftQty, aGroup.measure),
          'stock.lots_count'.plural(aGroup.lots.length),
          if (per100 != null) per100Line(aContext, per100, aIsMl: aGroup.measure == StockMeasure.ml),
        ].join(' · '),
        style: TextStyle(fontSize: 12, color: palette.inkMuted),
      ),
      children: [for (final lot in aGroup.lots) _lotTile(aContext, lot)],
    );
  }

  Widget _batchTile(BuildContext aContext, StockLot aLot)
  {
    final palette = aContext.palette;
    final per100 = aLot.per100;
    final cost = aLot.leftCost;
    final currCode = aLot.currCode;
    return ListTile(
      key: ValueKey('stock.batch.${aLot.id}'),
      contentPadding: const EdgeInsets.only(left: 12, right: 4),
      leading: Icon(AppIcons.cookingPot, color: palette.inkSecondary),
      title: Text(aLot.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          'stock.cooked_on'.tr(args: [DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aLot.acquiredTs)]),
          'stock.left_of_total'.tr(args: [formatStockQty(aContext, aLot.leftQty, aLot.measure), formatStockQty(aContext, aLot.qty, aLot.measure)]),
          if (per100 != null) per100Line(aContext, per100),
          if (cost != null && currCode != null) formatMoney(aContext, cost, currCode),
        ].join(' · '),
        style: TextStyle(fontSize: 12, color: palette.inkMuted),
      ),
      trailing: _lotMenu(aLot),
    );
  }

  Widget _section(BuildContext aContext, {required String aTitle, required IconData aIcon, required List<Widget> aChildren, required String aEmpty})
  {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Row(
            children: [
              Icon(aIcon, size: 18, color: aContext.palette.inkSecondary),
              const SizedBox(width: 8),
              Text(aTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          semanticContainer: false,
          clipBehavior: Clip.antiAlias,
          child: aChildren.isEmpty ? BlockEmpty(aEmpty) : Column(children: aChildren),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(stockRevisionProv, (_, __) => _load());
    final settings = ref.watch(stockSettingsProv).valueOrNull;
    final data = _data;
    final Widget body;
    if (_error != null)
    {
      body = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (data == null)
    {
      body = const Center(child: CircularProgressIndicator());
    }
    else
    {
      final items = data.groupsOf(StockKind.item);
      final dishes = data.lots.where((aLot) => aLot.kind == StockKind.dish).toList();
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: screenPadding(aContext),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _storeBar(aContext, settings),
                    const SizedBox(height: 12),
                    _actions(aContext, data.store),
                    const SizedBox(height: 20),
                    _section(
                      aContext,
                      aTitle: 'stock.products'.tr(),
                      aIcon: AppIcons.shoppingBag,
                      aEmpty: 'stock.products_empty'.tr(),
                      aChildren: [for (final group in items) _itemGroup(aContext, group)],
                    ),
                    const SizedBox(height: 20),
                    _section(
                      aContext,
                      aTitle: 'stock.dishes'.tr(),
                      aIcon: AppIcons.cookingPot,
                      aEmpty: 'stock.dishes_empty'.tr(),
                      aChildren: [for (final lot in dishes) _batchTile(aContext, lot)],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SubPage(title: 'stock.title'.tr(), child: body);
  }
}
