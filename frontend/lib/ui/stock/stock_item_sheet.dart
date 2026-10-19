import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/money.dart';
import '../nutrition/nutrition_format.dart';
import 'stock_actions.dart';
import 'stock_format.dart';

enum _SheetAction { writeOff, pack, lotWriteOff, lotExpiry, lotDelete }

class _SheetChoice
{
  final _SheetAction action;
  final StockLot? lot;

  const _SheetChoice(this.action, [this.lot]);
}

String lotLine(BuildContext aContext, StockLot aLot)
{
  final cost = aLot.leftCost;
  final currCode = aLot.currCode;
  return [
    DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aLot.acquiredTs),
    sourceLabel(aLot.source),
    'stock.left_of_total'.tr(args: [
      aLot.isUnmeasured ? formatStockQty(aContext, aLot.leftQty, aLot.measure) : formatLotLeft(aContext, aLot),
      formatStockQty(aContext, aLot.qty, aLot.measure),
    ]),
    if (cost != null && currCode != null) formatMoney(aContext, cost, currCode),
  ].join(' · ');
}

Future<void> openStockGroup(BuildContext aContext, WidgetRef aRef, StockStoreRef aStore, StockGroup aGroup) async
{
  final choice = await showModalBottomSheet<_SheetChoice>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _StockGroupSheet(group: aGroup),
  );
  if (choice == null || !aContext.mounted)
  {
    return;
  }
  final lot = choice.lot;
  switch (choice.action)
  {
    case _SheetAction.writeOff:
      await writeOffGroupFlow(aContext, aRef, aStore, aGroup);
    case _SheetAction.pack:
      final itemId = aGroup.itemId;
      if (itemId != null)
      {
        await packMassFlow(aContext, aRef, itemId, aGroup.title);
      }
    case _SheetAction.lotWriteOff when lot != null:
      await wasteLotFlow(aContext, aRef, lot);
    case _SheetAction.lotExpiry when lot != null:
      await expiryLotFlow(aContext, aRef, lot);
    case _SheetAction.lotDelete when lot != null:
      await deleteLotFlow(aContext, aRef, lot);
    default:
      break;
  }
}

class _StockGroupSheet extends StatelessWidget
{
  final StockGroup group;

  const _StockGroupSheet({required this.group});

  Widget _lotTile(BuildContext aContext, StockLot aLot)
  {
    final palette = aContext.palette;
    final today = DateTime.now();
    final expiry = expiryLabel(aContext, aLot, today);
    final tone = expiryTone(aLot, today);
    final expiryColor = switch (tone)
    {
      ExpiryTone.expired => palette.danger,
      ExpiryTone.soon => palette.warning,
      _ => palette.inkMuted,
    };

    return ListTile(
      key: ValueKey('stock.sheet.lot.${aLot.id}'),
      dense: true,
      contentPadding: const EdgeInsets.only(left: 4, right: 0),
      leading: Icon(sourceIcon(aLot.source), size: 18, color: palette.inkMuted),
      title: Text(lotLine(aContext, aLot), style: const TextStyle(fontSize: 13)),
      subtitle: expiry == null ? null : Text(expiry, style: TextStyle(fontSize: 12, color: expiryColor)),
      trailing: PopupMenuButton<_SheetAction>(
        key: ValueKey('stock.lot_menu.${aLot.id}'),
        tooltip: 'common.actions'.tr(),
        icon: const Icon(AppIcons.moreVertical, size: 18),
        onSelected: (aAction) => Navigator.of(aContext).pop(_SheetChoice(aAction, aLot)),
        itemBuilder: (_) => [
          PopupMenuItem(value: _SheetAction.lotWriteOff, child: Text('stock.writeoff_lot'.tr())),
          PopupMenuItem(value: _SheetAction.lotExpiry, child: Text('stock.expiry_action'.tr())),
          if (aLot.isRemovable)
            PopupMenuItem(
              value: _SheetAction.lotDelete,
              child: Text(aLot.source == StockSource.cooked ? 'stock.uncook'.tr() : 'common.delete'.tr()),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final media = MediaQuery.of(aContext);
    final per100 = group.first.per100;
    final isUnmeasured = group.isUnmeasured && group.itemId != null;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + media.padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(group.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'stock.left_of'.tr(args: [formatGroupLeft(aContext, group)]),
              key: const ValueKey('stock.sheet.left'),
              style: TextStyle(color: palette.inkSecondary),
            ),
            if (per100 != null)
              Text(
                per100Line(aContext, per100, aIsMl: group.measure == StockMeasure.ml),
                style: TextStyle(fontSize: 12, color: palette.inkMuted),
              ),
            if (isUnmeasured) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: palette.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(AppIcons.scale, size: 18, color: palette.warning),
                    const SizedBox(width: 10),
                    Expanded(child: Text('stock.pack_missing'.tr(), style: TextStyle(fontSize: 13, color: palette.inkPrimary))),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('stock.sheet.writeoff'),
                  onPressed: () => Navigator.of(aContext).pop(const _SheetChoice(_SheetAction.writeOff)),
                  icon: const Icon(AppIcons.minus, size: 18),
                  label: Text('stock.writeoff_action'.tr()),
                ),
                if (isUnmeasured)
                  OutlinedButton.icon(
                    key: const ValueKey('stock.sheet.pack'),
                    onPressed: () => Navigator.of(aContext).pop(const _SheetChoice(_SheetAction.pack)),
                    icon: const Icon(AppIcons.scale, size: 18),
                    label: Text('stock.pack_set'.tr()),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('stock.lots_title'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
            for (final lot in group.lots) _lotTile(aContext, lot),
          ],
        ),
      ),
    );
  }
}
