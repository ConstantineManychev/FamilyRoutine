import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../common/page_frames.dart';
import 'product_cats.dart';

const double _contentMaxWidth = 860;
const double _indentStep = 20;
const String _defaultConvertCode = 'UAH';
const String _convertToPref = 'items.convert_to';
const int _branchItemsLimit = 200;
const List<int?> _periods = [30, 90, 365, null];

String _periodLabel(int? aDays) => switch (aDays)
{
  null => 'cats.period_all'.tr(),
  365 => 'cats.period_year'.tr(),
  _ => 'cats.period_days'.tr(args: ['$aDays']),
};

class ProductCatsScreen extends ConsumerStatefulWidget
{
  const ProductCatsScreen({super.key});

  @override
  ConsumerState<ProductCatsScreen> createState() => _ProductCatsScreenState();
}

class _ProductCatsScreenState extends ConsumerState<ProductCatsScreen>
{
  final Set<String> _expanded = {};

  Future<void> _open(String aId) async
  {
    await context.push('/app/product-cats/$aId');
    ref.invalidate(productCatsProv);
  }

  Widget _tile(BuildContext aContext, ProductCatTree aTree, ProductCat aCat, int aIndent)
  {
    final palette = aContext.palette;
    final children = aTree.children(aCat.id);
    final isExpanded = _expanded.contains(aCat.id);
    final count = aTree.branchItemCount(aCat.id);

    return ListTile(
      key: ValueKey('cat.${aCat.id}'),
      contentPadding: EdgeInsets.only(left: 8 + aIndent * _indentStep, right: 12),
      onTap: () => _open(aCat.id),
      leading: children.isEmpty
          ? const SizedBox(width: 40)
          : IconButton(
              tooltip: isExpanded ? 'cats.collapse'.tr() : 'cats.expand'.tr(),
              onPressed: () => setState(() => isExpanded ? _expanded.remove(aCat.id) : _expanded.add(aCat.id)),
              icon: Icon(isExpanded ? AppIcons.chevronDown : AppIcons.chevronRight, size: 18),
            ),
      title: Text(catLabel(aCat)),
      subtitle: count == 0 ? null : Text('cats.items_count'.plural(count), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
      trailing: aCat.ownerKind == ItemOwnerKind.me ? Icon(AppIcons.user, size: 16, color: palette.inkMuted) : null,
    );
  }

  List<Widget> _branch(BuildContext aContext, ProductCatTree aTree, String? aParentId, int aIndent)
  {
    final tiles = <Widget>[];
    for (final cat in sortedChildren(aTree, aParentId))
    {
      tiles.add(_tile(aContext, aTree, cat, aIndent));
      if (_expanded.contains(cat.id))
      {
        tiles.addAll(_branch(aContext, aTree, cat.id, aIndent + 1));
      }
    }
    return tiles;
  }

  Widget _list(BuildContext aContext, String aQuery)
  {
    final treeAsync = ref.watch(productCatsProv);
    return treeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(productCatsProv)),
      data: (aTree)
      {
        final List<Widget> tiles;
        if (aQuery.isEmpty)
        {
          tiles = _branch(aContext, aTree, null, 0);
        }
        else
        {
          final found = aTree.nodes.where((aCat) => catLabel(aCat).toLowerCase().contains(aQuery)).toList()
            ..sort((aLeft, aRight) => catPathLabel(aTree, aLeft.id).compareTo(catPathLabel(aTree, aRight.id)));
          tiles = [
            if (found.isEmpty) BlockEmpty('cats.nothing_found'.tr()),
            for (final cat in found)
              ListTile(
                onTap: () => _open(cat.id),
                title: Text(catLabel(cat)),
                subtitle: Text(catPathLabel(aTree, cat.id), style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted)),
              ),
          ];
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(productCatsProv.future),
          child: ListView(padding: const EdgeInsets.only(bottom: fabClearance), children: tiles),
        );
      },
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final tree = ref.watch(productCatsProv).valueOrNull;
    return ListPage(
      title: 'cats.title'.tr(),
      addTooltip: 'cats.new_root'.tr(),
      onAdd: tree == null ? null : () => createProductCat(aContext, ref, tree, null),
      searchHint: 'cats.search'.tr(),
      builder: _list,
    );
  }
}

class ProductCatScreen extends ConsumerStatefulWidget
{
  final String catId;

  const ProductCatScreen({super.key, required this.catId});

  @override
  ConsumerState<ProductCatScreen> createState() => _ProductCatScreenState();
}

class _ProductCatScreenState extends ConsumerState<ProductCatScreen>
{
  CatPrices? _prices;
  Object? _pricesError;
  List<DictItemDto>? _items;
  List<CurrencyDto> _currencies = const [];
  List<PlaceDto> _places = const [];
  String _convertCode = _defaultConvertCode;
  int? _days = 365;
  String? _placeId;

  @override
  void initState()
  {
    super.initState();
    _init();
  }

  Future<void> _init() async
  {
    try
    {
      final prefs = await SharedPreferences.getInstance();
      _convertCode = prefs.getString(_convertToPref) ?? _defaultConvertCode;
    }
    on Exception
    {
      _convertCode = _defaultConvertCode;
    }
    final api = ref.read(apiProv);
    try
    {
      final currencies = await api.getCurrencies();
      final places = await api.getPlaces();
      if (mounted)
      {
        setState(()
        {
          _currencies = currencies;
          _places = places;
        });
      }
    }
    catch (_)
    {
    }
    await Future.wait([_loadPrices(), _loadItems()]);
  }

  Future<void> _loadPrices() async
  {
    try
    {
      final prices = await ref.read(apiProv).getCatPrices(widget.catId, aConvertTo: _convertCode, aDays: _days, aPlaceId: _placeId);
      if (mounted)
      {
        setState(()
        {
          _prices = prices;
          _pricesError = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _pricesError = aError);
      }
    }
  }

  Future<void> _loadItems() async
  {
    try
    {
      final items = await ref.read(apiProv).getItems(aCatId: widget.catId, aLimit: _branchItemsLimit);
      if (mounted)
      {
        setState(() => _items = items);
      }
    }
    catch (_)
    {
      if (mounted)
      {
        setState(() => _items = const []);
      }
    }
  }

  void _setFilter({int? aDays, bool aIsDaysChanged = false, String? aCode, String? aPlaceId, bool aIsPlaceChanged = false})
  {
    setState(()
    {
      if (aIsDaysChanged)
      {
        _days = aDays;
      }
      if (aCode != null)
      {
        _convertCode = aCode;
      }
      if (aIsPlaceChanged)
      {
        _placeId = aPlaceId;
      }
      _prices = null;
    });
    _loadPrices();
  }

  Future<void> _openItem(String aId) async
  {
    await context.push('/app/items/$aId');
    ref.invalidate(productCatsProv);
    await Future.wait([_loadPrices(), _loadItems()]);
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    try
    {
      await aAction();
      ref.invalidate(productCatsProv);
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  Future<void> _rename(ProductCat aCat) async
  {
    final name = await askCatName(context, aTitle: 'cats.rename'.tr(), aInitial: catLabel(aCat));
    if (name != null)
    {
      await _run(() => ref.read(apiProv).saveProductCat(aCat.id, name, aCat.parentId));
    }
  }

  Future<void> _move(ProductCat aCat) async
  {
    final picked = await pickProductCat(context, aInitialId: aCat.parentId, aExcludeId: aCat.id, aIsRootAllowed: true);
    if (picked != null && picked.catId != aCat.parentId)
    {
      await _run(() => ref.read(apiProv).saveProductCat(aCat.id, aCat.name, picked.catId));
    }
  }

  Future<void> _merge(ProductCat aCat) async
  {
    final picked = await pickProductCat(context, aExcludeId: aCat.id);
    final targetId = picked?.catId;
    if (targetId == null || !mounted)
    {
      return;
    }
    final tree = ref.read(productCatsProv).valueOrNull;
    final target = tree?[targetId];
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'cats.merge'.tr(),
      aMessage: 'cats.merge_confirm'.tr(args: [catLabel(aCat), target == null ? '' : catLabel(target)]),
    );
    if (!isConfirmed)
    {
      return;
    }
    await _run(() => ref.read(apiProv).mergeProductCat(aCat.id, targetId));
    if (mounted)
    {
      context.pushReplacement('/app/product-cats/$targetId');
    }
  }

  Future<void> _delete(ProductCat aCat) async
  {
    final isConfirmed = await confirmAction(context, aTitle: 'cats.delete'.tr(), aMessage: 'cats.delete_confirm'.tr());
    if (!isConfirmed)
    {
      return;
    }
    try
    {
      await ref.read(apiProv).deleteProductCat(aCat.id);
      ref.invalidate(productCatsProv);
      if (mounted)
      {
        closePage(context);
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

  Widget _filters(BuildContext aContext)
  {
    final codes = {_defaultConvertCode, 'EUR', 'USD', ..._currencies.map((aCurrency) => aCurrency.code)}.toList()..sort();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final days in _periods)
          ChoiceChip(
            label: Text(_periodLabel(days)),
            selected: _days == days,
            showCheckmark: false,
            onSelected: (_) => _setFilter(aDays: days, aIsDaysChanged: true),
          ),
        DropdownButton<String>(
          value: codes.contains(_convertCode) ? _convertCode : _defaultConvertCode,
          isDense: true,
          items: codes.map((aCode) => DropdownMenuItem(value: aCode, child: Text(aCode))).toList(),
          onChanged: (aValue) => _setFilter(aCode: aValue ?? _defaultConvertCode),
        ),
        if (_places.isNotEmpty)
          DropdownButton<String?>(
            value: _places.any((aPlace) => aPlace.id == _placeId) ? _placeId : null,
            isDense: true,
            items: [
              DropdownMenuItem<String?>(value: null, child: Text('cats.all_stores'.tr())),
              for (final place in _places) DropdownMenuItem<String?>(value: place.id, child: Text(place.name)),
            ],
            onChanged: (aValue) => _setFilter(aPlaceId: aValue, aIsPlaceChanged: true),
          ),
      ],
    );
  }

  Widget _ranking(BuildContext aContext)
  {
    final palette = aContext.palette;
    final prices = _prices;
    if (_pricesError != null)
    {
      return ErrorRetry(error: _pricesError!, onRetry: _loadPrices);
    }
    if (prices == null)
    {
      return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }

    final groups = <NetMeasure, List<CatPriceRow>>{};
    for (final row in prices.rows)
    {
      groups.putIfAbsent(row.measure, () => []).add(row);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (prices.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('cats.no_prices'.tr(), style: TextStyle(color: palette.inkMuted)),
          ),
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              'cats.per_100_${entry.key.name}'.tr(),
              style: TextStyle(fontWeight: FontWeight.w700, color: palette.inkSecondary),
            ),
          ),
          for (final (index, row) in entry.value.indexed) _PriceRowTile(rank: index + 1, row: row, onTap: () => _openItem(row.itemId)),
        ],
        if (prices.isMissingRates) ...[
          const SizedBox(height: 8),
          Text('cats.missing_rates'.tr(), style: TextStyle(fontSize: 12, color: palette.warning)),
        ],
        if (prices.unmeasured.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('cats.unmeasured'.tr(), style: TextStyle(fontSize: 13, color: palette.inkSecondary)),
          for (final item in prices.unmeasured)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              onTap: () => _openItem(item.id),
              leading: Icon(AppIcons.scale, size: 18, color: palette.warning),
              title: Text(item.name),
              trailing: const Icon(AppIcons.chevronRight, size: 16),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final palette = aContext.palette;
    final treeAsync = ref.watch(productCatsProv);
    final tree = treeAsync.valueOrNull;
    final cat = tree?[widget.catId];
    if (tree == null || cat == null)
    {
      return SubPage(
        child: treeAsync.hasError
            ? ErrorRetry(error: treeAsync.error!, onRetry: () => ref.invalidate(productCatsProv))
            : (tree == null ? const Center(child: CircularProgressIndicator()) : Center(child: Text('cats.missing'.tr()))),
      );
    }

    final path = tree.path(cat.id);
    final children = sortedChildren(tree, cat.id);
    final canChange = cat.canChange;
    final items = _items;

    return SubPage(
      title: catLabel(cat),
      actions: [
        if (tree.canAddChild(cat.id))
          IconButton(
            tooltip: 'cats.add_child'.tr(),
            onPressed: () => createProductCat(aContext, ref, tree, cat.id),
            icon: const Icon(AppIcons.plus),
          ),
        if (canChange || tree.isAdmin)
          PopupMenuButton<String>(
            tooltip: 'common.actions'.tr(),
            icon: const Icon(AppIcons.moreVertical),
            onSelected: (aAction) => switch (aAction)
            {
              'rename' => _rename(cat),
              'move' => _move(cat),
              'merge' => _merge(cat),
              _ => _delete(cat),
            },
            itemBuilder: (_) => [
              if (canChange) PopupMenuItem(value: 'rename', child: Text('cats.rename'.tr())),
              if (canChange) PopupMenuItem(value: 'move', child: Text('cats.move'.tr())),
              if (tree.isAdmin) PopupMenuItem(value: 'merge', child: Text('cats.merge'.tr())),
              if (canChange) PopupMenuItem(value: 'delete', enabled: children.isEmpty, child: Text('cats.delete'.tr())),
            ],
          ),
      ],
      child: ListView(
        padding: screenPadding(aContext),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (index, node) in path.indexed) ...[
                        if (index > 0) Icon(AppIcons.chevronRight, size: 14, color: palette.inkMuted),
                        TextButton(
                          onPressed: node.id == cat.id ? null : () => context.pushReplacement('/app/product-cats/${node.id}'),
                          child: Text(catLabel(node)),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    [
                      catLevelLabel(cat.depth),
                      if (cat.isInUse && cat.ownerKind == ItemOwnerKind.me) 'cats.in_use'.tr(),
                    ].join(' · '),
                    style: TextStyle(color: palette.inkSecondary),
                  ),
                  if (children.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final child in children)
                          ActionChip(
                            avatar: const Icon(AppIcons.folderTree, size: 16),
                            label: Text(catLabel(child)),
                            onPressed: () => context.push('/app/product-cats/${child.id}'),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text('cats.best_prices'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('cats.best_prices_hint'.tr(), style: TextStyle(color: palette.inkSecondary)),
                  const SizedBox(height: 12),
                  _filters(aContext),
                  _ranking(aContext),
                  const SizedBox(height: 24),
                  Text('cats.items'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  if (items == null)
                    const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
                  else if (items.isEmpty)
                    Text('cats.no_items'.tr(), style: TextStyle(color: palette.inkMuted))
                  else
                    for (final item in items)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        onTap: () => _openItem(item.id),
                        title: Text(item.name),
                        subtitle: item.catId == cat.id || item.catId == null
                            ? null
                            : Text(catPathLabel(tree, item.catId), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
                        trailing: const Icon(AppIcons.chevronRight, size: 16),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PriceRowTile extends StatelessWidget
{
  final int rank;
  final CatPriceRow row;
  final VoidCallback onTap;

  const _PriceRowTile({required this.rank, required this.row, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final unit = 'cats.per_100_short_${row.measure.name}'.tr();
    final best = '${formatMoney(aContext, row.best100, row.currCode)} $unit';
    final isFirst = rank == 1;
    final where = [
      if (row.bestStore != null) row.bestStore!,
      if (row.bestBranch != null) row.bestBranch!,
      formatDate(aContext, row.bestTs),
    ].join(' · ');
    final last = row.lastTs.isAfter(row.bestTs) && row.last100 != row.best100
        ? 'cats.last_price'.tr(args: [formatMoney(aContext, row.last100, row.currCode), formatDate(aContext, row.lastTs)])
        : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 28,
              child: isFirst
                  ? Icon(AppIcons.trophy, size: 18, color: palette.positive)
                  : Text('$rank', style: TextStyle(color: palette.inkMuted, fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(row.itemName, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(where, style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
                  if (last != null) Text(last, style: TextStyle(fontSize: 12, color: palette.inkMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              best,
              style: TextStyle(fontWeight: FontWeight.w700, color: isFirst ? palette.positive : palette.inkPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
