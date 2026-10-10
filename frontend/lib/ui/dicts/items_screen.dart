import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import 'item_form.dart';

final AutoDisposeFutureProviderFamily<List<DictItemDto>, String> itemsProv =
    FutureProvider.autoDispose.family<List<DictItemDto>, String>((aRef, aQuery) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getItems(aQuery: aQuery);
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

  final _searchCtrl = TextEditingController();
  Timer? _searchTimer;
  String _query = '';

  @override
  void dispose()
  {
    _searchTimer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
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
    final itemsAsync = ref.watch(itemsProv(_query));

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'items.title'.tr(),
            actions: [
              ElevatedButton.icon(
                onPressed: () => aContext.go('/app/items/new'),
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('items.add'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: TextField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: 'items.search'.tr(),
                prefixIcon: const Icon(AppIcons.search, size: 18),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(itemsProv(_query))),
              data: (aItems) => aItems.isEmpty
                  ? Center(child: Text(_query.isEmpty ? 'items.empty'.tr() : 'common.no_data'.tr()))
                  : ListView.builder(
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
      if (!item.isCustom) 'items.shared'.tr(),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(itemKindIcon(item.kind), color: Colors.blue.shade700),
        title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(details),
        trailing: const Icon(AppIcons.chevronRight),
        onTap: () => aContext.go('/app/items/${item.id}'),
      ),
    );
  }
}
