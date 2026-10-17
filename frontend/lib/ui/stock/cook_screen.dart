import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../nutrition/nutrition_format.dart';
import 'stock_format.dart';

const double _maxIngredientG = 20000;
const double _maxCookedG = 100000;
const double _cookedRatioLimit = 10;
const List<double> _scales = [0.5, 1, 1.5, 2];

Future<CookBatch?> showCookScreen(BuildContext aContext, {required String aDishId, required StockStoreRef aStore})
{
  return Navigator.of(aContext).push<CookBatch>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => CookScreen(dishId: aDishId, store: aStore),
  ));
}

class CookScreen extends ConsumerStatefulWidget
{
  final String dishId;
  final StockStoreRef store;

  const CookScreen({super.key, required this.dishId, required this.store});

  @override
  ConsumerState<CookScreen> createState() => _CookScreenState();
}

class _CookScreenState extends ConsumerState<CookScreen>
{
  Dish? _dish;
  Map<String, double> _available = const {};
  Object? _error;
  final List<TextEditingController> _gramCtrls = [];
  final _cookedCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  double _scale = 1;
  bool _isBusy = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    for (final ctrl in _gramCtrls)
    {
      ctrl.dispose();
    }
    _cookedCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    try
    {
      final api = ref.read(apiProv);
      final dish = await api.getDish(widget.dishId);
      final stock = await api.getStock(aStore: widget.store);
      final available = <String, double>{};
      for (final lot in stock.lots.where((aLot) => aLot.kind == StockKind.item && aLot.itemId != null))
      {
        final grams = lot.measure.isMass ? lot.leftQty : (lot.pieceG == null ? 0.0 : lot.leftQty * lot.pieceG!);
        available.update(lot.itemId!, (aValue) => aValue + grams, ifAbsent: () => grams);
      }
      if (!mounted)
      {
        return;
      }
      setState(()
      {
        _dish = dish;
        _available = available;
        _error = null;
        _gramCtrls.addAll(dish.ingredients.map((aIngredient) => TextEditingController(text: amountText(aIngredient.grams))));
        _cookedCtrl.text = amountText(dish.cookedG.roundToDouble());
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _applyScale(double aScale)
  {
    final dish = _dish;
    if (dish == null)
    {
      return;
    }
    setState(()
    {
      _scale = aScale;
      for (var index = 0; index < dish.ingredients.length; index++)
      {
        _gramCtrls[index].text = amountText((dish.ingredients[index].grams * aScale).roundToDouble());
      }
      _cookedCtrl.text = amountText((dish.cookedG * aScale).roundToDouble());
    });
  }

  List<double?> get _grams => _gramCtrls.map((aCtrl) => parseAmountText(aCtrl.text)).toList();

  double get _rawG => _grams.fold(0, (aSum, aValue) => aSum + (aValue ?? 0));

  double? get _cookedG => parseAmountText(_cookedCtrl.text);

  bool get _isValid
  {
    final grams = _grams;
    if (grams.isEmpty || grams.any((aValue) => aValue == null || aValue <= 0 || aValue > _maxIngredientG))
    {
      return false;
    }
    final cooked = _cookedG;
    final raw = _rawG;
    return cooked != null && cooked > 0 && cooked <= _maxCookedG && cooked * _cookedRatioLimit >= raw && cooked <= raw * _cookedRatioLimit;
  }

  Macros? get _preview
  {
    final dish = _dish;
    final cooked = _cookedG;
    if (dish == null || cooked == null || cooked <= 0)
    {
      return null;
    }
    final grams = _grams;
    var total = Macros.zero;
    for (var index = 0; index < dish.ingredients.length; index++)
    {
      final per100 = dish.ingredients[index].per100;
      final value = grams[index];
      if (per100 != null && value != null)
      {
        total = total + per100.forGrams(value);
      }
    }
    return total.forGrams(100 * 100 / cooked);
  }

  Future<void> _cook() async
  {
    final dish = _dish;
    if (dish == null || !_isValid)
    {
      return;
    }
    final grams = _grams;
    setState(() => _isBusy = true);
    try
    {
      final batch = await ref.read(apiProv).cookDish(
            aStore: widget.store,
            aDishId: dish.id,
            aCookedG: _cookedG!,
            aIngredients: [
              for (var index = 0; index < dish.ingredients.length; index++)
                CookIngredient(itemId: dish.ingredients[index].itemId, itemName: dish.ingredients[index].itemName, grams: grams[index]!),
            ],
            aNote: _noteCtrl.text,
          );
      notifyStockChanged(ref);
      if (mounted)
      {
        Navigator.of(context).pop(batch);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isBusy = false);
      }
    }
  }

  Widget _ingredientRow(BuildContext aContext, DishIngredient aIngredient, int aIndex)
  {
    final palette = aContext.palette;
    final need = _grams[aIndex] ?? 0;
    final have = _available[aIngredient.itemId] ?? 0;
    final isShort = have + 0.05 < need;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(aIngredient.itemName, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  have <= 0
                      ? 'stock.cook_none'.tr()
                      : 'stock.cook_have'.tr(args: [formatStockQty(aContext, have, StockMeasure.g)]),
                  key: ValueKey('cook.have.$aIndex'),
                  style: TextStyle(fontSize: 12, color: isShort ? palette.warning : palette.inkMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: TextField(
              key: ValueKey('cook.grams.$aIndex'),
              controller: _gramCtrls[aIndex],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(isDense: true, suffixText: 'stock.measure_g'.tr(), border: const OutlineInputBorder()),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final dish = _dish;
    final palette = aContext.palette;
    final Widget body;
    if (_error != null)
    {
      body = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (dish == null)
    {
      body = const Center(child: CircularProgressIndicator());
    }
    else
    {
      final preview = _preview;
      body = ListView(
        padding: screenPadding(aContext),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(dish.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('stock.cook_into'.tr(args: [storeLabel(widget.store)]), style: TextStyle(color: palette.inkSecondary)),
                  const SizedBox(height: 12),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<double>(
                      showSelectedIcon: false,
                      segments: [
                        for (final scale in _scales) ButtonSegment(value: scale, label: Text('×${amountText(scale)}')),
                      ],
                      selected: {_scale},
                      onSelectionChanged: (aValue) => _applyScale(aValue.first),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('stock.cook_ingredients'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)),
                  for (var index = 0; index < dish.ingredients.length; index++) _ingredientRow(aContext, dish.ingredients[index], index),
                  Text(
                    'stock.cook_raw'.tr(args: [formatStockQty(aContext, _rawG, StockMeasure.g)]),
                    style: TextStyle(fontSize: 12, color: palette.inkMuted),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('cook.cooked'),
                    controller: _cookedCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(8)],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'stock.cook_weight'.tr(),
                      helperText: 'stock.cook_weight_hint'.tr(),
                      suffixText: 'stock.measure_g'.tr(),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteCtrl,
                    inputFormatters: [LengthLimitingTextInputFormatter(500)],
                    decoration: InputDecoration(labelText: 'stock.note'.tr(), border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: palette.surfaceMuted, borderRadius: BorderRadius.circular(12)),
                    child: Row(
                      children: [
                        Icon(AppIcons.flame, size: 18, color: palette.inkSecondary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            preview == null ? '—' : per100Line(aContext, preview),
                            key: const ValueKey('cook.preview'),
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('stock.cook_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('cook.save'),
                    onPressed: _isValid && !_isBusy ? _cook : null,
                    icon: const Icon(AppIcons.cookingPot, size: 18),
                    label: Text('stock.cook_action'.tr()),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return SubPage(title: 'stock.cook_title'.tr(), child: body);
  }
}
