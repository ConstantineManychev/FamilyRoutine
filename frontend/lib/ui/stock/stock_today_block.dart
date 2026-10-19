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
import 'stock_actions.dart';
import 'stock_format.dart';
import 'stock_item_sheet.dart';

const int _shownGroups = 5;

final AutoDisposeFutureProvider<StockData> activeStockProv = FutureProvider.autoDispose<StockData>((aRef)
{
  aRef.watch(stockRevisionProv);
  return aRef.read(apiProv).getStock();
});

Widget? _urgentExpiry(BuildContext aContext, StockGroup aGroup)
{
  final lot = aGroup.soonest;
  if (lot == null)
  {
    return null;
  }
  final today = DateTime.now();
  final tone = expiryTone(lot, today);
  final label = expiryLabel(aContext, lot, today);
  if (label == null || (tone != ExpiryTone.soon && tone != ExpiryTone.expired))
  {
    return null;
  }
  final color = tone == ExpiryTone.expired ? aContext.palette.danger : aContext.palette.warning;
  return Text(label, style: TextStyle(fontSize: 12, color: color));
}

class StockTodayBlock extends ConsumerWidget
{
  const StockTodayBlock({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final stockAsync = aRef.watch(activeStockProv);
    final data = stockAsync.valueOrNull;
    final palette = aContext.palette;
    final Widget content = stockAsync.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(activeStockProv)),
      data: (aData)
      {
        final groups = [...aData.groupsOf(StockKind.dish), ...aData.groupsOf(StockKind.item)];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'stock.block_store'.tr(args: [storeLabel(aData.store)]),
                key: const ValueKey('stock.block_store'),
                style: TextStyle(fontSize: 12, color: palette.inkMuted),
              ),
            ),
            if (groups.isEmpty)
              BlockEmpty('stock.block_empty'.tr())
            else
              for (final group in groups.take(_shownGroups))
                ListTile(
                  key: ValueKey('stock.block.${group.key}'),
                  dense: true,
                  onTap: () => group.kind == StockKind.dish
                      ? wasteLotFlow(aContext, aRef, group.first)
                      : openStockGroup(aContext, aRef, aData.store, group),
                  leading: Icon(group.kind == StockKind.dish ? AppIcons.cookingPot : AppIcons.shoppingBag, size: 18, color: palette.inkSecondary),
                  title: Text(group.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: _urgentExpiry(aContext, group),
                  trailing: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      formatGroupLeft(aContext, group),
                      textAlign: TextAlign.end,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: group.isUnmeasured ? palette.warning : palette.inkSecondary),
                    ),
                  ),
                ),
            if (groups.length > _shownGroups)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('stock.block_more'.tr(args: ['${groups.length - _shownGroups}']), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ),
          ],
        );
      },
    );

    return BlockCard(
      title: 'stock.title'.tr(),
      onAdd: data == null ? null : () => addLotFlow(aContext, aRef, data.store),
      addTooltip: 'stock.add'.tr(),
      onExpand: () => aContext.push(stockPath),
      child: content,
    );
  }
}
