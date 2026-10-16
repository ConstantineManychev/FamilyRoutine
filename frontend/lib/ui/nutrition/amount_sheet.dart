import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'nutrition_format.dart';

const double maxEntryGrams = 10000;
const double maxPortions = 50;
const List<double> _gramPresets = [50, 100, 150, 200, 250];
const List<double> _portionPresets = [0.5, 1, 1.5, 2];

enum AmountUnit { grams, portions }

class AmountTarget
{
  final String title;
  final Macros per100;
  final double? portionG;
  final bool isDish;
  final bool isMl;

  const AmountTarget({required this.title, required this.per100, this.portionG, this.isDish = false, this.isMl = false});

  factory AmountTarget.item(DictItemDto aItem) => AmountTarget(
        title: aItem.name,
        per100: Macros.fromNutrition(aItem.nutrition),
        portionG: aItem.nutrition.pieceG,
        isMl: aItem.unit == ItemUnit.liter,
      );

  factory AmountTarget.dish(Dish aDish) => AmountTarget(title: aDish.name, per100: aDish.per100, portionG: aDish.portionG, isDish: true);

  factory AmountTarget.entry(MealEntry aEntry) => AmountTarget(
        title: entryTitle(aEntry),
        per100: aEntry.per100 ?? Macros.zero,
        portionG: aEntry.portionG,
        isDish: aEntry.source == MealSource.dish,
        isMl: aEntry.isMl,
      );
}

class AmountResult
{
  final MealSlot meal;
  final double? grams;
  final double? portions;
  final bool isDelete;

  const AmountResult({required this.meal, this.grams, this.portions, this.isDelete = false});

  Map<String, dynamic> toJson() => {
        'meal': meal.name,
        if (portions != null) 'portions': amountText(portions) else 'grams': amountText(grams),
      };
}

Future<AmountResult?> showAmountSheet(
  BuildContext aContext, {
  required AmountTarget aTarget,
  required MealSlot aMeal,
  double? aGrams,
  double? aPortions,
  bool aIsEdit = false,
})
{
  return showModalBottomSheet<AmountResult>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AmountSheet(target: aTarget, meal: aMeal, grams: aGrams, portions: aPortions, isEdit: aIsEdit),
  );
}

class AmountSheet extends StatefulWidget
{
  final AmountTarget target;
  final MealSlot meal;
  final double? grams;
  final double? portions;
  final bool isEdit;

  const AmountSheet({super.key, required this.target, required this.meal, this.grams, this.portions, this.isEdit = false});

  @override
  State<AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends State<AmountSheet>
{
  late MealSlot _meal = widget.meal;
  late AmountUnit _unit = widget.portions != null && widget.target.portionG != null ? AmountUnit.portions : AmountUnit.grams;
  late final TextEditingController _ctrl = TextEditingController(text: amountText(_initialValue()));

  double? _initialValue()
  {
    if (_unit == AmountUnit.portions)
    {
      return widget.portions ?? 1;
    }
    return widget.grams ?? widget.target.portionG ?? 100;
  }

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  double? get _value => parseAmountText(_ctrl.text);

  double? get _grams
  {
    final value = _value;
    if (value == null)
    {
      return null;
    }
    return _unit == AmountUnit.portions ? value * (widget.target.portionG ?? 0) : value;
  }

  bool get _isValid
  {
    final value = _value;
    final grams = _grams;
    if (value == null || grams == null || value <= 0 || grams <= 0 || grams > maxEntryGrams)
    {
      return false;
    }
    return _unit == AmountUnit.grams || value <= maxPortions;
  }

  void _switchUnit(AmountUnit aUnit)
  {
    final portionG = widget.target.portionG;
    final grams = _grams;
    setState(()
    {
      _unit = aUnit;
      if (portionG != null && grams != null && grams > 0)
      {
        _ctrl.text = amountText(aUnit == AmountUnit.portions ? double.parse((grams / portionG).toStringAsFixed(2)) : grams.roundToDouble());
      }
    });
  }

  void _submit()
  {
    if (!_isValid)
    {
      return;
    }
    final value = _value!;
    Navigator.of(context).pop(AmountResult(
      meal: _meal,
      grams: _unit == AmountUnit.grams ? value : null,
      portions: _unit == AmountUnit.portions ? value : null,
    ));
  }

  String _portionUnitLabel() => widget.target.isDish ? 'nutrition.unit_portions'.tr() : 'nutrition.unit_pieces'.tr();

  @override
  Widget build(BuildContext aContext)
  {
    final media = MediaQuery.of(aContext);
    final palette = aContext.palette;
    final target = widget.target;
    final portionG = target.portionG;
    final grams = _grams;
    final preview = grams == null ? null : target.per100.forGrams(grams);
    final presets = _unit == AmountUnit.portions ? _portionPresets : _gramPresets;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: (media.size.height - media.viewInsets.bottom) * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(target.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(per100Line(aContext, target.per100, aIsMl: target.isMl), style: TextStyle(color: palette.inkSecondary)),
                    if (portionG != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        (target.isDish ? 'nutrition.portion_is' : 'nutrition.piece_is').tr(args: [formatGrams(aContext, portionG, aIsMl: target.isMl)]),
                        style: TextStyle(color: palette.inkSecondary),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (portionG != null) ...[
                      SegmentedButton<AmountUnit>(
                        segments: [
                          ButtonSegment(value: AmountUnit.grams, label: Text(target.isMl ? 'nutrition.unit_ml'.tr() : 'nutrition.unit_grams'.tr())),
                          ButtonSegment(value: AmountUnit.portions, label: Text(_portionUnitLabel())),
                        ],
                        selected: {_unit},
                        showSelectedIcon: false,
                        onSelectionChanged: (aSelected) => _switchUnit(aSelected.first),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      key: const ValueKey('nutrition.amount'),
                      controller: _ctrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')), LengthLimitingTextInputFormatter(7)],
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: _unit == AmountUnit.portions
                            ? _portionUnitLabel()
                            : (target.isMl ? 'nutrition.amount_ml'.tr() : 'nutrition.amount_grams'.tr()),
                        border: const OutlineInputBorder(),
                        errorText: _ctrl.text.trim().isEmpty || _isValid ? null : 'nutrition.amount_invalid'.tr(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final preset in presets)
                          ActionChip(
                            label: Text(amountText(preset)),
                            onPressed: () => setState(() => _ctrl.text = amountText(preset)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('nutrition.meal'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final meal in MealSlot.values)
                          ChoiceChip(
                            avatar: Icon(mealIcon(meal), size: 16),
                            label: Text(mealLabel(meal)),
                            selected: _meal == meal,
                            showCheckmark: false,
                            onSelected: (_) => setState(() => _meal = meal),
                          ),
                      ],
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
                              preview == null ? '—' : '${formatKcal(aContext, preview.kcal)} · ${macrosLine(aContext, preview)}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 20, 16 + media.padding.bottom),
              child: Row(
                children: [
                  if (widget.isEdit)
                    IconButton(
                      tooltip: 'common.delete'.tr(),
                      color: palette.danger,
                      onPressed: () => Navigator.of(aContext).pop(AmountResult(meal: _meal, isDelete: true)),
                      icon: const Icon(AppIcons.trash2),
                    ),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isValid ? _submit : null,
                    child: Text(widget.isEdit ? 'common.save'.tr() : 'nutrition.add'.tr()),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
