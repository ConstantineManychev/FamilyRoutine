import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/barcode_scanner.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'item_form.dart';
import '../common/app_theme.dart';

typedef ItemsFilter = ({String query, bool isMine});

final AutoDisposeFutureProviderFamily<List<DictItemDto>, ItemsFilter> itemsProv =
    FutureProvider.autoDispose.family<List<DictItemDto>, ItemsFilter>((aRef, aFilter) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getItems(aQuery: aFilter.query, aIsMine: aFilter.isMine);
});

class ItemsScreen extends ConsumerStatefulWidget
{
  const ItemsScreen({super.key});

  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen>
{
  static const Duration _searchDelay = Duration(milliseconds: 300);

  Timer? _searchTimer;
  String _query = '';
  bool _isMine = false;

  ItemsFilter get _filter => (query: _query, isMine: _isMine);

  @override
  void dispose()
  {
    _searchTimer?.cancel();
    super.dispose();
  }

  Future<void> _scan() async
  {
    final code = await scanBarcode(context);
    if (code == null || !mounted)
    {
      return;
    }

    try
    {
      final found = await ref.read(apiProv).getItems(aBarcode: code, aLimit: 1);
      if (!mounted)
      {
        return;
      }
      final item = found.firstOrNull;
      context.push(item == null ? Uri(path: '/app/items/new', queryParameters: {'barcode': code}).toString() : '/app/items/${item.id}');
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  void _onSearchChanged(String aValue)
  {
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDelay, ()
    {
      if (mounted)
      {
        setState(() => _query = aValue.trim());
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final itemsAsync = ref.watch(itemsProv(_filter));

    return ListPage(
      title: 'items.title'.tr(),
      onAdd: () => aContext.push('/app/items/new'),
      addTooltip: 'items.add'.tr(),
      onSearch: _onSearchChanged,
      searchHint: 'items.search_barcode'.tr(),
      actions: [
        IconButton(tooltip: 'scanner.title'.tr(), icon: const Icon(AppIcons.scanBarcode), onPressed: _scan),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                label: Text('items.only_mine'.tr()),
                selected: _isMine,
                onSelected: (aValue) => setState(() => _isMine = aValue),
              ),
            ),
          ),
          Expanded(
            child: itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(itemsProv(_filter))),
              data: (aItems) => aItems.isEmpty
                  ? Center(child: Text(_query.isEmpty && !_isMine ? 'items.empty'.tr() : 'common.no_data'.tr()))
                  : ListView.builder(
                      key: const PageStorageKey('list.items'),
                      padding: screenPadding(aContext),
                      itemCount: aItems.length,
                      itemBuilder: (_, aIndex) => _ItemTile(item: aItems[aIndex]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget
{
  final DictItemDto item;

  const _ItemTile({required this.item});

  @override
  Widget build(BuildContext aContext)
  {
    final details = [
      itemKindLabel(item.kind),
      itemUnitShort(item.unit),
      if (item.barcode != null) item.barcode!,
      itemOwnerLabel(item),
    ].join(' · ');
    final nutrition = nutritionSummary(item.nutrition);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(itemKindIcon(item.kind), color: aContext.colors.primary),
        title: Text(item.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(nutrition == null ? details : '$details\n$nutrition'),
        trailing: const Icon(AppIcons.chevronRight),
        onTap: () => aContext.push('/app/items/${item.id}'),
      ),
    );
  }
}
