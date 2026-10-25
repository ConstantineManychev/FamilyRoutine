import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../dicts/product_cats.dart';

const double _indentStep = 20;

Map<String, int> stockCountsByCat(ProductCatTree aTree, StockFoods aStock)
{
  final counts = <String, int>{};
  for (final catId in aStock.itemCats.values.whereType<String>())
  {
    for (final node in aTree.path(catId))
    {
      counts[node.id] = (counts[node.id] ?? 0) + 1;
    }
  }
  return counts;
}

class FoodCatsPanel extends ConsumerStatefulWidget
{
  final StockFoods? stock;
  final bool isStockOnly;
  final bool isEnabled;
  final ValueChanged<ProductCat> onPick;

  const FoodCatsPanel({super.key, required this.stock, required this.isStockOnly, required this.onPick, this.isEnabled = true});

  @override
  ConsumerState<FoodCatsPanel> createState() => _FoodCatsPanelState();
}

class _FoodCatsPanelState extends ConsumerState<FoodCatsPanel>
{
  final Set<String> _expanded = {};
  String _query = '';

  bool _isVisible(ProductCat aCat, Map<String, int> aCounts) => !widget.isStockOnly || (aCounts[aCat.id] ?? 0) > 0;

  String? _subtitle(ProductCatTree aTree, ProductCat aCat, Map<String, int> aCounts, {bool aIsPath = false})
  {
    final count = aCounts[aCat.id] ?? 0;
    final parts = [
      if (aIsPath) catPathLabel(aTree, aCat.id),
      if (count > 0) 'nutrition.cat_in_stock'.tr(args: ['$count']),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _tile(BuildContext aContext, ProductCatTree aTree, ProductCat aCat, Map<String, int> aCounts, int aIndent)
  {
    final palette = aContext.palette;
    final children = aTree.children(aCat.id).where((aChild) => _isVisible(aChild, aCounts)).toList();
    final isExpanded = _expanded.contains(aCat.id);
    final subtitle = _subtitle(aTree, aCat, aCounts);
    return ListTile(
      key: ValueKey('food.cat.${aCat.code ?? aCat.id}'),
      contentPadding: EdgeInsets.only(left: 8 + aIndent * _indentStep, right: 8),
      enabled: widget.isEnabled,
      onTap: () => widget.onPick(aCat),
      leading: children.isEmpty
          ? const SizedBox(width: 40)
          : IconButton(
              tooltip: isExpanded ? 'cats.collapse'.tr() : 'cats.expand'.tr(),
              onPressed: () => setState(() => isExpanded ? _expanded.remove(aCat.id) : _expanded.add(aCat.id)),
              icon: Icon(isExpanded ? AppIcons.chevronDown : AppIcons.chevronRight, size: 18),
            ),
      title: Text(catLabel(aCat)),
      subtitle: subtitle == null ? null : Text(subtitle, style: TextStyle(fontSize: 12, color: palette.inkMuted)),
      trailing: Icon(AppIcons.plus, color: aContext.colors.primary),
    );
  }

  List<Widget> _branch(BuildContext aContext, ProductCatTree aTree, String? aParentId, Map<String, int> aCounts, int aIndent)
  {
    final tiles = <Widget>[];
    for (final cat in sortedChildren(aTree, aParentId).where((aCat) => _isVisible(aCat, aCounts)))
    {
      tiles.add(_tile(aContext, aTree, cat, aCounts, aIndent));
      if (_expanded.contains(cat.id))
      {
        tiles.addAll(_branch(aContext, aTree, cat.id, aCounts, aIndent + 1));
      }
    }
    return tiles;
  }

  List<Widget> _matches(BuildContext aContext, ProductCatTree aTree, Map<String, int> aCounts)
  {
    final query = _query.toLowerCase();
    final found = aTree.nodes
        .where((aCat) => catLabel(aCat).toLowerCase().contains(query) && _isVisible(aCat, aCounts))
        .toList()
      ..sort((aLeft, aRight) => catPathLabel(aTree, aLeft.id).compareTo(catPathLabel(aTree, aRight.id)));
    return [
      for (final cat in found)
        ListTile(
          key: ValueKey('food.cat.${cat.code ?? cat.id}'),
          enabled: widget.isEnabled,
          onTap: () => widget.onPick(cat),
          title: Text(catLabel(cat)),
          subtitle: Text(
            _subtitle(aTree, cat, aCounts, aIsPath: true) ?? '',
            style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
          ),
          trailing: Icon(AppIcons.plus, color: aContext.colors.primary),
        ),
    ];
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final palette = aContext.palette;
    final treeAsync = ref.watch(productCatsProv);
    final stock = widget.stock;

    return treeAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(productCatsProv)),
      data: (aTree)
      {
        if (widget.isStockOnly && stock == null)
        {
          return const Center(child: CircularProgressIndicator());
        }
        final counts = stock == null ? const <String, int>{} : stockCountsByCat(aTree, stock);
        final tiles = _query.isEmpty ? _branch(aContext, aTree, null, counts, 0) : _matches(aContext, aTree, counts);
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                key: const ValueKey('food.cat_search'),
                inputFormatters: [LengthLimitingTextInputFormatter(maxCatNameLen)],
                onChanged: (aValue) => setState(() => _query = aValue.trim()),
                decoration: InputDecoration(
                  hintText: 'cats.search'.tr(),
                  prefixIcon: const Icon(AppIcons.search, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: palette.surfaceMuted,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text('nutrition.cat_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
            ),
            if (tiles.isEmpty)
              BlockEmpty(widget.isStockOnly ? 'nutrition.stock_empty'.tr() : 'cats.nothing_found'.tr())
            else
              ...tiles,
          ],
        );
      },
    );
  }
}
