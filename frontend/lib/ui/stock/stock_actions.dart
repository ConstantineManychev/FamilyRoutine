import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import '../nutrition/food_picker.dart';
import '../nutrition/nutrition_format.dart';
import 'cook_screen.dart';
import 'stock_dialogs.dart';
import 'stock_format.dart';

Future<bool> _run(BuildContext aContext, WidgetRef aRef, Future<void> Function() aAction) async
{
  try
  {
    await aAction();
    notifyStockChanged(aRef);
    return true;
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
    return false;
  }
}

Future<bool> addLotFlow(BuildContext aContext, WidgetRef aRef, StockStoreRef aStore) async
{
  final item = await pickFood(aContext);
  if (item == null || !aContext.mounted)
  {
    return false;
  }
  final api = aRef.read(apiProv);
  List<CurrencyDto> currencies;
  try
  {
    currencies = await api.getCurrencies();
  }
  catch (_)
  {
    currencies = const [];
  }
  if (!aContext.mounted)
  {
    return false;
  }
  final preferred = currencies.where((aCurrency) => aCurrency.code == 'UAH').firstOrNull?.id;
  final draft = await showAddLotDialog(aContext, item, currencies, preferred);
  if (draft == null || !aContext.mounted)
  {
    return false;
  }
  final isDone = await _run(
    aContext,
    aRef,
    () => api.createStockLot(
      aStore: aStore,
      aItemId: item.id,
      aQty: draft.qty,
      aUnit: draft.unit,
      aCost: draft.cost,
      aCurrId: draft.currId,
      aAcquiredOn: draft.acquiredOn,
      aExpiresOn: draft.expiresOn,
    ),
  );
  if (isDone && aContext.mounted)
  {
    showInfoSnack(aContext, 'stock.added'.tr(args: [item.name]));
  }
  return isDone;
}

Future<bool> wasteLotFlow(BuildContext aContext, WidgetRef aRef, StockLot aLot) async
{
  final draft = await showWasteDialog(aContext, aLot);
  if (draft == null || !aContext.mounted)
  {
    return false;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).wasteStockLot(aLot.id, draft.qty, draft.reason, draft.note));
}

Future<bool> expiryLotFlow(BuildContext aContext, WidgetRef aRef, StockLot aLot) async
{
  final choice = await showExpiryDialog(aContext, aLot);
  if (choice == null || !aContext.mounted)
  {
    return false;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).setStockLotExpiry(aLot.id, choice.expiresOn));
}

Future<bool> deleteLotFlow(BuildContext aContext, WidgetRef aRef, StockLot aLot) async
{
  final isCooked = aLot.source == StockSource.cooked;
  final isConfirmed = await confirmAction(
    aContext,
    aTitle: isCooked ? 'stock.uncook_title'.tr() : 'stock.delete_title'.tr(),
    aMessage: isCooked ? 'stock.uncook_message'.tr(args: [aLot.title]) : 'stock.delete_message'.tr(args: [aLot.title]),
  );
  if (!isConfirmed || !aContext.mounted)
  {
    return false;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).deleteStockLot(aLot.id));
}

Future<CookBatch?> cookFlow(BuildContext aContext, WidgetRef aRef, StockStoreRef? aStore, {String? aDishId}) async
{
  var store = aStore;
  if (store == null)
  {
    try
    {
      store = (await aRef.read(apiProv).getStockSettings()).active.ref;
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
      return null;
    }
    if (!aContext.mounted)
    {
      return null;
    }
  }
  var dishId = aDishId;
  if (dishId == null)
  {
    final dishes = await aRef.read(apiProv).getDishes();
    if (!aContext.mounted)
    {
      return null;
    }
    if (dishes.isEmpty)
    {
      showInfoSnack(aContext, 'stock.no_dishes'.tr());
      return null;
    }
    final picked = await showDialog<Dish>(
      context: aContext,
      builder: (aDialogContext) => SimpleDialog(
        title: Text('stock.pick_dish'.tr()),
        children: [
          for (final dish in dishes)
            SimpleDialogOption(
              key: ValueKey('cook.dish.${dish.id}'),
              onPressed: () => Navigator.of(aDialogContext).pop(dish),
              child: Text(dish.name),
            ),
        ],
      ),
    );
    if (picked == null || !aContext.mounted)
    {
      return null;
    }
    dishId = picked.id;
  }
  final batch = await showCookScreen(aContext, aDishId: dishId, aStore: store);
  if (batch != null && aContext.mounted)
  {
    final message = 'stock.cooked'.tr(args: [batch.title, formatStockQty(aContext, batch.cookedG, StockMeasure.g), formatKcal(aContext, batch.per100.kcal)]);
    showInfoSnack(aContext, batch.shortG > 0 ? '$message ${'stock.cooked_short'.tr(args: [formatStockQty(aContext, batch.shortG, StockMeasure.g)])}' : message);
  }
  return batch;
}
