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
import 'amount_sheet.dart';
import 'food_picker.dart';
import 'nutrition_format.dart';

const double _contentMaxWidth = 720;
const int _maxIngredients = 50;
const double _maxIngredientG = 20000;
const double _maxCookedG = 100000;
const double _cookedRatioLimit = 10;
const double _maxServingG = 10000;
const int _maxServings = 100;
const int _maxNameLen = 100;
const int _maxNoteLen = 500;

enum PortionMode { none, weight, count }

class _IngredientRow
{
  DishIngredient ingredient;
  final TextEditingController gramsCtrl;

  _IngredientRow(this.ingredient) : gramsCtrl = TextEditingController(text: amountText(ingredient.grams));

  double? get grams => parseAmountText(gramsCtrl.text);

  DishIngredient get current => ingredient.withGrams(grams ?? 0);
}

class DishDraft
{
  final List<DishIngredient> ingredients;
  final double? cookedG;
  final PortionMode mode;
  final double? servingG;
  final int? servings;

  const DishDraft({required this.ingredients, this.cookedG, this.mode = PortionMode.none, this.servingG, this.servings});

  DishMath get math => DishMath.compute(
        ingredients,
        aCookedG: cookedG,
        aServingG: mode == PortionMode.weight ? servingG : null,
        aServings: mode == PortionMode.count ? servings : null,
      );

  String? validate()
  {
    if (ingredients.isEmpty)
    {
      return 'nutrition.err_no_ingredients'.tr();
    }
    if (ingredients.length > _maxIngredients)
    {
      return 'nutrition.err_too_many_ingredients'.tr();
    }
    if (ingredients.any((aItem) => aItem.grams <= 0 || aItem.grams > _maxIngredientG))
    {
      return 'nutrition.err_ingredient_grams'.tr();
    }
    final raw = math.rawG;
    final cooked = cookedG;
    if (cooked != null && (cooked <= 0 || cooked > _maxCookedG || cooked * _cookedRatioLimit < raw || cooked > raw * _cookedRatioLimit))
    {
      return 'nutrition.err_cooked'.tr();
    }
    if (mode == PortionMode.weight && (servingG == null || servingG! <= 0 || servingG! > _maxServingG))
    {
      return 'nutrition.err_serving'.tr();
    }
    if (mode == PortionMode.count && (servings == null || servings! < 1 || servings! > _maxServings))
    {
      return 'nutrition.err_servings'.tr();
    }
    return null;
  }
}

class DishEditorScreen extends ConsumerStatefulWidget
{
  final String? dishId;

  const DishEditorScreen({super.key, this.dishId});

  @override
  ConsumerState<DishEditorScreen> createState() => _DishEditorScreenState();
}

class _DishEditorScreenState extends ConsumerState<DishEditorScreen>
{
  final _nameCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _cookedCtrl = TextEditingController();
  final _servingCtrl = TextEditingController();
  final _servingsCtrl = TextEditingController();
  final List<_IngredientRow> _rows = [];
  Dish? _dish;
  Object? _error;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isCookedEdited = false;
  bool _isShared = false;
  PortionMode _mode = PortionMode.none;

  bool get _isNew => widget.dishId == null;

  bool get _isEditable => _isNew || (_dish?.isEditable ?? false);

  @override
  void initState()
  {
    super.initState();
    if (!_isNew)
    {
      _load();
    }
  }

  @override
  void dispose()
  {
    for (final ctrl in [_nameCtrl, _noteCtrl, _cookedCtrl, _servingCtrl, _servingsCtrl])
    {
      ctrl.dispose();
    }
    for (final row in _rows)
    {
      row.gramsCtrl.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async
  {
    setState(()
    {
      _isLoading = true;
      _error = null;
    });
    try
    {
      final dish = await ref.read(apiProv).getDish(widget.dishId!);
      if (!mounted)
      {
        return;
      }
      for (final row in _rows)
      {
        row.gramsCtrl.dispose();
      }
      _rows
        ..clear()
        ..addAll(dish.ingredients.map(_IngredientRow.new));
      _nameCtrl.text = dish.name;
      _noteCtrl.text = dish.note ?? '';
      _isCookedEdited = dish.isCookedSet;
      _cookedCtrl.text = amountText(dish.cookedG);
      _isShared = dish.isShared;
      _mode = dish.servingG != null ? PortionMode.weight : (dish.servings != null ? PortionMode.count : PortionMode.none);
      _servingCtrl.text = amountText(dish.servingG);
      _servingsCtrl.text = dish.servings?.toString() ?? '';
      setState(()
      {
        _dish = dish;
        _isLoading = false;
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(()
        {
          _error = aError;
          _isLoading = false;
        });
      }
    }
  }

  DishDraft get _draft => DishDraft(
        ingredients: _rows.map((aRow) => aRow.current).toList(),
        cookedG: _isCookedEdited ? parseAmountText(_cookedCtrl.text) : null,
        mode: _mode,
        servingG: parseAmountText(_servingCtrl.text),
        servings: int.tryParse(_servingsCtrl.text.trim()),
      );

  void _syncCooked()
  {
    if (!_isCookedEdited)
    {
      _cookedCtrl.text = amountText(_draft.math.rawG);
    }
    setState(() {});
  }

  Future<void> _addIngredient() async
  {
    final item = await pickFood(context);
    if (item == null || !mounted)
    {
      return;
    }
    _rows.add(_IngredientRow(DishIngredient.fromItem(item, item.nutrition.pieceG ?? 100)));
    _syncCooked();
  }

  void _removeIngredient(int aIndex)
  {
    _rows.removeAt(aIndex).gramsCtrl.dispose();
    _syncCooked();
  }

  void _resetCooked()
  {
    _isCookedEdited = false;
    _syncCooked();
  }

  Future<void> _save() async
  {
    final name = _nameCtrl.text.trim();
    final draft = _draft;
    final error = name.isEmpty ? 'nutrition.err_name'.tr() : draft.validate();
    if (error != null)
    {
      showInfoSnack(context, error);
      return;
    }
    final cooked = draft.cookedG;
    final note = _noteCtrl.text.trim();
    setState(() => _isSaving = true);
    try
    {
      await ref.read(apiProv).saveDish(
            widget.dishId,
            Dish.payload(
              aName: name,
              aNote: note.isEmpty ? null : note,
              aCookedG: cooked != null && (cooked - draft.math.rawG).abs() >= 0.05 ? cooked : null,
              aServingG: _mode == PortionMode.weight ? draft.servingG : null,
              aServings: _mode == PortionMode.count ? draft.servings : null,
              aIsShared: _isShared,
              aIngredients: draft.ingredients,
            ),
          );
      if (mounted)
      {
        finishPage(context, '/app/dishes');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'nutrition.delete_dish'.tr(),
      aMessage: 'nutrition.delete_dish_hint'.tr(),
    );
    if (!isConfirmed || !mounted)
    {
      return;
    }
    try
    {
      await ref.read(apiProv).deleteDish(widget.dishId!);
      if (mounted)
      {
        finishPage(context, '/app/dishes');
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

  Future<void> _addToDiary() async
  {
    final dish = _dish;
    if (dish == null)
    {
      return;
    }
    final now = DateTime.now();
    final result = await showAmountSheet(
      context,
      aTarget: AmountTarget.dish(dish),
      aMeal: MealSlot.forHour(now.hour),
      aPortions: dish.portionG != null ? 1 : null,
    );
    if (result == null || !mounted)
    {
      return;
    }
    try
    {
      await ref.read(apiProv).addMealEntry({'date': dateWire(now), 'dish_id': dish.id, ...result.toJson()});
      if (mounted)
      {
        notifyNutritionChanged(ref);
        showInfoSnack(context, 'nutrition.added'.tr(args: [dish.name, mealLabel(result.meal)]));
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

  Widget _numberField(
    TextEditingController aCtrl,
    String aLabel, {
    String? aHelper,
    bool aIsInteger = false,
    bool aIsEnabled = true,
    ValueChanged<String>? aOnChanged,
    Widget? aSuffix,
    Key? aKey,
  })
  {
    return TextField(
      key: aKey,
      controller: aCtrl,
      enabled: aIsEnabled,
      keyboardType: TextInputType.numberWithOptions(decimal: !aIsInteger),
      inputFormatters: [
        FilteringTextInputFormatter.allow(aIsInteger ? RegExp(r'[0-9]') : RegExp(r'[0-9.,]')),
        LengthLimitingTextInputFormatter(aIsInteger ? 3 : 8),
      ],
      onChanged: aOnChanged ?? (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: aLabel,
        helperText: aHelper,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: aSuffix,
      ),
    );
  }

  Widget _ingredientTile(BuildContext aContext, int aIndex)
  {
    final palette = aContext.palette;
    final row = _rows[aIndex];
    final ingredient = row.current;
    final per100 = ingredient.per100;
    final pieceG = ingredient.pieceG;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ingredient.itemName, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  per100 == null
                      ? 'nutrition.no_nutrition'.tr()
                      : '${formatKcal(aContext, ingredient.total.kcal)} · ${macrosLine(aContext, ingredient.total)}',
                  style: TextStyle(fontSize: 12, color: per100 == null ? palette.warning : palette.inkSecondary),
                ),
                if (pieceG != null)
                  Text('nutrition.piece_is'.tr(args: [formatGrams(aContext, pieceG)]), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: TextField(
              key: ValueKey('dish.grams.$aIndex'),
              controller: row.gramsCtrl,
              enabled: _isEditable,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
              onChanged: (_) => _syncCooked(),
              decoration: InputDecoration(labelText: 'nutrition.unit_grams'.tr(), border: const OutlineInputBorder(), isDense: true),
            ),
          ),
          if (_isEditable)
            IconButton(
              tooltip: 'common.delete'.tr(),
              onPressed: () => _removeIngredient(aIndex),
              icon: const Icon(AppIcons.x, size: 18),
            ),
        ],
      ),
    );
  }

  Widget _results(BuildContext aContext, DishMath aMath)
  {
    final palette = aContext.palette;
    final portionG = aMath.portionG;
    final portion = portionG == null ? null : aMath.per100.forGrams(portionG);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: palette.surfaceMuted, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('nutrition.per_100_cooked'.tr(), style: TextStyle(color: palette.inkSecondary)),
          const SizedBox(height: 2),
          Text(
            '${formatKcal(aContext, aMath.per100.kcal)} · ${macrosLine(aContext, aMath.per100)}',
            key: const ValueKey('dish.per100'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (portion != null) ...[
            const SizedBox(height: 10),
            Text('nutrition.per_portion'.tr(args: [formatGrams(aContext, portionG!)]), style: TextStyle(color: palette.inkSecondary)),
            const SizedBox(height: 2),
            Text(
              '${formatKcal(aContext, portion.kcal)} · ${macrosLine(aContext, portion)}',
              key: const ValueKey('dish.portion'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'nutrition.dish_total'.tr(args: [
              formatGrams(aContext, aMath.rawG),
              formatGrams(aContext, aMath.cookedG),
              formatKcal(aContext, aMath.total.kcal),
            ]),
            style: TextStyle(fontSize: 12, color: palette.inkMuted),
          ),
          if (aMath.missingCount > 0) ...[
            const SizedBox(height: 6),
            Text('nutrition.missing_count'.plural(aMath.missingCount), style: TextStyle(fontSize: 12, color: palette.warning)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final palette = aContext.palette;
    final title = _isNew ? 'nutrition.new_dish'.tr() : (_dish?.name ?? 'nutrition.dish'.tr());
    final dish = _dish;
    final actions = <Widget>[
      if (dish != null)
        IconButton(tooltip: 'nutrition.add_to_diary'.tr(), onPressed: _addToDiary, icon: const Icon(AppIcons.plusCircle)),
      if (dish != null && dish.isEditable)
        IconButton(tooltip: 'common.delete'.tr(), onPressed: _delete, icon: const Icon(AppIcons.trash2)),
    ];

    if (_isLoading || (!_isNew && dish == null))
    {
      return SubPage(
        title: title,
        child: _error != null ? ErrorRetry(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator()),
      );
    }

    final math = _draft.math;
    final isEditable = _isEditable;

    return SubPage(
      title: title,
      actions: actions,
      child: ListView(
        padding: screenPadding(aContext),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!isEditable && dish?.ownerName != null) ...[
                    Text('nutrition.dish_of'.tr(args: [dish!.ownerName!]), style: TextStyle(color: palette.inkSecondary)),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    key: const ValueKey('dish.name'),
                    controller: _nameCtrl,
                    enabled: isEditable,
                    inputFormatters: [LengthLimitingTextInputFormatter(_maxNameLen)],
                    decoration: InputDecoration(labelText: 'nutrition.dish_name'.tr(), border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Text('nutrition.ingredients'.tr(), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      if (isEditable && _rows.length < _maxIngredients)
                        TextButton.icon(
                          onPressed: _addIngredient,
                          icon: const Icon(AppIcons.plus, size: 18),
                          label: Text('nutrition.add_ingredient'.tr()),
                        ),
                    ],
                  ),
                  if (_rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('nutrition.ingredients_empty'.tr(), style: TextStyle(color: palette.inkMuted)),
                    ),
                  for (var index = 0; index < _rows.length; index++) _ingredientTile(aContext, index),
                  const SizedBox(height: 16),
                  _numberField(
                    _cookedCtrl,
                    'nutrition.cooked_g'.tr(),
                    aKey: const ValueKey('dish.cooked'),
                    aHelper: 'nutrition.cooked_hint'.tr(args: [formatGrams(aContext, math.rawG)]),
                    aIsEnabled: isEditable,
                    aOnChanged: (_) => setState(() => _isCookedEdited = true),
                    aSuffix: _isCookedEdited && isEditable
                        ? IconButton(tooltip: 'nutrition.cooked_reset'.tr(), onPressed: _resetCooked, icon: const Icon(AppIcons.refreshCw, size: 18))
                        : null,
                  ),
                  const SizedBox(height: 16),
                  Text('nutrition.portion'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
                  const SizedBox(height: 8),
                  SegmentedButton<PortionMode>(
                    segments: [
                      ButtonSegment(value: PortionMode.none, label: Text('nutrition.portion_none'.tr())),
                      ButtonSegment(value: PortionMode.weight, label: Text('nutrition.portion_weight'.tr())),
                      ButtonSegment(value: PortionMode.count, label: Text('nutrition.portion_count'.tr())),
                    ],
                    selected: {_mode},
                    showSelectedIcon: false,
                    onSelectionChanged: isEditable ? (aSelected) => setState(() => _mode = aSelected.first) : null,
                  ),
                  if (_mode == PortionMode.weight) ...[
                    const SizedBox(height: 12),
                    _numberField(_servingCtrl, 'nutrition.serving_g'.tr(), aIsEnabled: isEditable, aKey: const ValueKey('dish.serving')),
                  ],
                  if (_mode == PortionMode.count) ...[
                    const SizedBox(height: 12),
                    _numberField(
                      _servingsCtrl,
                      'nutrition.servings'.tr(),
                      aIsInteger: true,
                      aIsEnabled: isEditable,
                      aKey: const ValueKey('dish.servings'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _results(aContext, math),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _noteCtrl,
                    enabled: isEditable,
                    maxLines: 3,
                    minLines: 1,
                    inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLen)],
                    decoration: InputDecoration(labelText: 'nutrition.note'.tr(), border: const OutlineInputBorder()),
                  ),
                  if (isEditable) ...[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _isShared,
                      onChanged: (aValue) => setState(() => _isShared = aValue),
                      title: Text('nutrition.share_dish'.tr()),
                      subtitle: Text('nutrition.share_dish_hint'.tr()),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ElevatedButton.icon(
                        onPressed: _isSaving ? null : _save,
                        icon: const Icon(AppIcons.save, size: 18),
                        label: Text('common.save'.tr()),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
