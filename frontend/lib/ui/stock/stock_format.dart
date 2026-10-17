import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';

const String stockPath = '/app/stock';
const double _kiloThreshold = 10000;

final StateProvider<int> stockRevisionProv = StateProvider<int>((aRef) => 0);

final AutoDisposeFutureProvider<StockSettings> stockSettingsProv = FutureProvider.autoDispose<StockSettings>((aRef)
{
  aRef.watch(stockRevisionProv);
  return aRef.read(apiProv).getStockSettings();
});

void notifyStockChanged(WidgetRef aRef) => aRef.read(stockRevisionProv.notifier).state++;

String stockHistoryPath(StockStoreRef aStore) => Uri(
      path: '/app/stock/history',
      queryParameters: aStore.isPersonal ? {'personal': 'true'} : {'family': aStore.familyId, 'name': aStore.familyName ?? ''},
    ).toString();

String storeLabel(StockStoreRef aStore) =>
    aStore.isPersonal ? 'stock.store_personal'.tr() : 'stock.store_group'.tr(args: [aStore.familyName ?? '']);

String measureLabel(StockMeasure aMeasure) => 'stock.measure_${aMeasure.name}'.tr();

String formatStockQty(BuildContext aContext, double aQty, StockMeasure aMeasure)
{
  final locale = aContext.locale.toLanguageTag();
  if (aMeasure.isMass && aQty >= _kiloThreshold)
  {
    final unit = aMeasure == StockMeasure.ml ? 'stock.measure_l'.tr() : 'stock.measure_kg'.tr();
    return '${NumberFormat('#,##0.##', locale).format(aQty / 1000)} $unit';
  }
  return '${NumberFormat('#,##0.#', locale).format(aQty)} ${measureLabel(aMeasure)}';
}

String sourceLabel(StockSource aSource) => 'stock.source_${aSource.name}'.tr();

String reasonLabel(WasteReason aReason) => 'stock.reason_${aReason.name}'.tr();

String moveKindLabel(StockMoveKind aKind) => 'stock.move_${aKind.name}'.tr();

IconData moveIcon(StockMoveKind aKind) => switch (aKind)
{
  StockMoveKind.eaten => AppIcons.utensils,
  StockMoveKind.cooked => AppIcons.cookingPot,
  StockMoveKind.waste => AppIcons.trash,
};

IconData sourceIcon(StockSource aSource) => switch (aSource)
{
  StockSource.receipt => AppIcons.receipt,
  StockSource.manual => AppIcons.plusCircle,
  StockSource.cooked => AppIcons.cookingPot,
};

StockMeasure? measureOfItem(DictItemDto aItem)
{
  if (aItem.kind == ItemKind.service)
  {
    return null;
  }
  return switch (aItem.unit)
  {
    ItemUnit.kilogram => StockMeasure.g,
    ItemUnit.liter => StockMeasure.ml,
    ItemUnit.piece => aItem.netQty != null && aItem.netMeasure != null
        ? (aItem.netMeasure == NetMeasure.ml ? StockMeasure.ml : StockMeasure.g)
        : aItem.nutrition.pieceG != null
            ? StockMeasure.g
            : StockMeasure.pcs,
    _ => null,
  };
}

double? pieceAmountOf(DictItemDto aItem, StockMeasure aMeasure)
{
  if (aMeasure == StockMeasure.pcs)
  {
    return 1;
  }
  final netQty = aItem.netQty;
  final netMeasure = aItem.netMeasure;
  if (netQty != null && netMeasure != null && (netMeasure == NetMeasure.ml) == (aMeasure == StockMeasure.ml))
  {
    return netQty;
  }
  return aMeasure == StockMeasure.g ? aItem.nutrition.pieceG : null;
}
