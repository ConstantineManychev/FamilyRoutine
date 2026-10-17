import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/money.dart';
import '../nutrition/nutrition_format.dart';
import 'stock_format.dart';

const int _maxNoteLen = 500;
const double _maxLotQty = 1000000;
const int _maxDaysBack = 3650;

final RegExp _numberInput = RegExp(r'[0-9.,]');

class WasteDraft
{
  final double qty;
  final WasteReason reason;
  final String? note;

  const WasteDraft({required this.qty, required this.reason, this.note});
}

Future<WasteDraft?> showWasteDialog(BuildContext aContext, StockLot aLot)
{
  return showDialog<WasteDraft>(context: aContext, builder: (_) => WasteDialog(lot: aLot));
}

class WasteDialog extends StatefulWidget
{
  final StockLot lot;

  const WasteDialog({super.key, required this.lot});

  @override
  State<WasteDialog> createState() => _WasteDialogState();
}

class _WasteDialogState extends State<WasteDialog>
{
  late final _qtyCtrl = TextEditingController(text: amountText(widget.lot.leftQty));
  final _noteCtrl = TextEditingController();
  WasteReason _reason = WasteReason.spoiled;

  @override
  void dispose()
  {
    _qtyCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double? get _qty
  {
    final value = parseAmountText(_qtyCtrl.text);
    return value == null || value <= 0 || value > widget.lot.leftQty ? null : value;
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final lot = widget.lot;
    final qty = _qty;
    final cost = lot.cost;
    final currCode = lot.currCode;
    final share = qty == null || cost == null || currCode == null || lot.qty <= 0 ? null : cost * qty / lot.qty;

    return AlertDialog(
      scrollable: true,
      title: Text('stock.waste_title'.tr(args: [lot.title])),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('waste.qty'),
              controller: _qtyCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(_numberInput), LengthLimitingTextInputFormatter(9)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'stock.waste_qty'.tr(),
                suffixText: measureLabel(lot.measure),
                helperText: 'stock.left_of'.tr(args: [formatStockQty(aContext, lot.leftQty, lot.measure)]),
                errorText: _qtyCtrl.text.trim().isEmpty || qty != null ? null : 'stock.err_waste_qty'.tr(),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('stock.reason'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final reason in WasteReason.values)
                  ChoiceChip(
                    key: ValueKey('waste.reason.${reason.name}'),
                    showCheckmark: false,
                    label: Text(reasonLabel(reason)),
                    selected: _reason == reason,
                    onSelected: (_) => setState(() => _reason = reason),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              minLines: 1,
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLen)],
              decoration: InputDecoration(labelText: 'stock.note'.tr(), border: const OutlineInputBorder()),
            ),
            if (share != null && currCode != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'stock.waste_cost'.tr(args: [formatMoney(aContext, share, currCode)]),
                  style: TextStyle(fontSize: 12, color: palette.inkMuted),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('waste.save'),
          onPressed: qty == null
              ? null
              : () => Navigator.of(aContext).pop(WasteDraft(qty: qty, reason: _reason, note: _noteCtrl.text.trim())),
          child: Text('stock.waste_action'.tr()),
        ),
      ],
    );
  }
}

class LotDraft
{
  final double qty;
  final StockMeasure unit;
  final double? cost;
  final String? currId;
  final DateTime acquiredOn;

  const LotDraft({required this.qty, required this.unit, this.cost, this.currId, required this.acquiredOn});
}

Future<LotDraft?> showAddLotDialog(BuildContext aContext, DictItemDto aItem, List<CurrencyDto> aCurrencies, String? aCurrId)
{
  return showDialog<LotDraft>(
    context: aContext,
    builder: (_) => AddLotDialog(item: aItem, currencies: aCurrencies, currId: aCurrId),
  );
}

class AddLotDialog extends StatefulWidget
{
  final DictItemDto item;
  final List<CurrencyDto> currencies;
  final String? currId;

  const AddLotDialog({super.key, required this.item, required this.currencies, this.currId});

  @override
  State<AddLotDialog> createState() => _AddLotDialogState();
}

class _AddLotDialogState extends State<AddLotDialog>
{
  final _qtyCtrl = TextEditingController();
  final _costCtrl = TextEditingController();
  late final StockMeasure? _measure = measureOfItem(widget.item);
  late StockMeasure? _unit = _measure;
  late String? _currId = widget.currId ?? widget.currencies.firstOrNull?.id;
  DateTime _acquiredOn = DateTime.now();

  @override
  void dispose()
  {
    _qtyCtrl.dispose();
    _costCtrl.dispose();
    super.dispose();
  }

  List<StockMeasure> get _units
  {
    final measure = _measure;
    if (measure == null)
    {
      return const [];
    }
    return [
      measure,
      if (measure != StockMeasure.pcs && pieceAmountOf(widget.item, measure) != null) StockMeasure.pcs,
    ];
  }

  double? get _qty
  {
    final value = parseAmountText(_qtyCtrl.text);
    return value == null || value <= 0 || value > _maxLotQty ? null : value;
  }

  double? get _cost => _costCtrl.text.trim().isEmpty ? null : parseAmountInput(_costCtrl.text);

  bool get _isCostValid => _costCtrl.text.trim().isEmpty || ((_cost ?? -1) >= 0 && _currId != null);

  Future<void> _pickDate() async
  {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _acquiredOn,
      firstDate: now.subtract(const Duration(days: _maxDaysBack)),
      lastDate: now,
    );
    if (picked != null && mounted)
    {
      setState(() => _acquiredOn = picked);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final unit = _unit;
    final qty = _qty;
    final isValid = unit != null && qty != null && _isCostValid;

    return AlertDialog(
      scrollable: true,
      title: Text(widget.item.name),
      content: SizedBox(
        width: 420,
        child: unit == null
            ? Text('stock.not_stockable'.tr(), style: TextStyle(color: palette.inkSecondary))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_units.length > 1) ...[
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final option in _units)
                          ChoiceChip(
                            key: ValueKey('lot.unit.${option.name}'),
                            showCheckmark: false,
                            label: Text(measureLabel(option)),
                            selected: unit == option,
                            onSelected: (_) => setState(() => _unit = option),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextField(
                    key: const ValueKey('lot.qty'),
                    controller: _qtyCtrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(_numberInput), LengthLimitingTextInputFormatter(9)],
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'stock.qty'.tr(),
                      suffixText: measureLabel(unit),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const ValueKey('lot.cost'),
                          controller: _costCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(_numberInput), LengthLimitingTextInputFormatter(12)],
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(labelText: 'stock.cost_optional'.tr(), border: const OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 110,
                        child: DropdownButtonFormField<String>(
                          initialValue: _currId,
                          isExpanded: true,
                          decoration: InputDecoration(labelText: 'stock.currency'.tr(), border: const OutlineInputBorder()),
                          items: [
                            for (final currency in widget.currencies)
                              DropdownMenuItem(value: currency.id, child: Text(currency.code)),
                          ],
                          onChanged: (aValue) => setState(() => _currId = aValue),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ActionChip(
                      avatar: const Icon(AppIcons.calendar, size: 16),
                      label: Text('stock.acquired_on'.tr(args: [DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(_acquiredOn)])),
                      onPressed: _pickDate,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('lot.save'),
          onPressed: isValid
              ? () => Navigator.of(aContext).pop(LotDraft(
                    qty: qty,
                    unit: unit,
                    cost: _cost,
                    currId: _cost == null ? null : _currId,
                    acquiredOn: _acquiredOn,
                  ))
              : null,
          child: Text('stock.add_to_stock'.tr()),
        ),
      ],
    );
  }
}
