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
const int _maxShelfDays = 3650;
const List<int> _quickShelfDays = [1, 3, 7, 30];

final RegExp _numberInput = RegExp(r'[0-9.,]');

class WriteOffSubject
{
  final String title;
  final StockMeasure measure;
  final double leftQty;
  final double totalQty;
  final double? packSize;
  final double? cost;
  final String? currCode;

  const WriteOffSubject({
    required this.title,
    required this.measure,
    required this.leftQty,
    required this.totalQty,
    this.packSize,
    this.cost,
    this.currCode,
  });

  factory WriteOffSubject.lot(StockLot aLot) => WriteOffSubject(
        title: aLot.title,
        measure: aLot.measure,
        leftQty: aLot.leftQty,
        totalQty: aLot.qty,
        packSize: aLot.isPackKnown ? aLot.packSize : null,
        cost: aLot.cost,
        currCode: aLot.currCode,
      );

  factory WriteOffSubject.group(StockGroup aGroup) => WriteOffSubject(
        title: aGroup.title,
        measure: aGroup.measure,
        leftQty: aGroup.leftQty,
        totalQty: aGroup.leftQty,
        packSize: aGroup.packSize,
        cost: aGroup.lots.where((aLot) => aLot.measure == aGroup.measure).fold<double>(0, (aSum, aLot) => aSum + (aLot.leftCost ?? 0)),
        currCode: aGroup.lots.map((aLot) => aLot.currCode).whereType<String>().toSet().length == 1 ? aGroup.first.currCode : null,
      );

  bool get isUnmeasured => measure == StockMeasure.pcs;

  List<StockMeasure> get units => [measure, if (measure != StockMeasure.pcs && packSize != null) StockMeasure.pcs];

  double? inMeasure(double aQty, StockMeasure aUnit)
  {
    if (aUnit == measure)
    {
      return aQty;
    }
    final pack = packSize;
    return aUnit == StockMeasure.pcs && pack != null ? aQty * pack : null;
  }
}

class WriteOffDraft
{
  final double qty;
  final StockMeasure unit;
  final WasteReason? reason;
  final String? note;
  final bool isPackRequested;

  const WriteOffDraft({required this.qty, required this.unit, this.reason, this.note}) : isPackRequested = false;

  const WriteOffDraft.packRequested()
      : qty = 0,
        unit = StockMeasure.g,
        reason = null,
        note = null,
        isPackRequested = true;
}

const List<WasteReason?> writeOffReasons = [null, WasteReason.spoiled, WasteReason.expired, WasteReason.leftovers, WasteReason.other];

String writeOffReasonLabel(WasteReason? aReason) => aReason == null ? 'stock.reason_used'.tr() : reasonLabel(aReason);

Future<WriteOffDraft?> showWriteOffDialog(BuildContext aContext, WriteOffSubject aSubject, {bool aCanAskPack = false})
{
  return showDialog<WriteOffDraft>(
    context: aContext,
    builder: (_) => WriteOffDialog(subject: aSubject, canAskPack: aCanAskPack),
  );
}

class WriteOffDialog extends StatefulWidget
{
  final WriteOffSubject subject;
  final bool canAskPack;

  const WriteOffDialog({super.key, required this.subject, this.canAskPack = false});

  @override
  State<WriteOffDialog> createState() => _WriteOffDialogState();
}

class _WriteOffDialogState extends State<WriteOffDialog>
{
  late StockMeasure _unit = widget.subject.measure;
  late final _qtyCtrl = TextEditingController(text: amountText(widget.subject.leftQty));
  final _noteCtrl = TextEditingController();
  WasteReason? _reason;

  @override
  void dispose()
  {
    _qtyCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double? get _amount
  {
    final value = parseAmountText(_qtyCtrl.text);
    if (value == null || value <= 0)
    {
      return null;
    }
    final amount = widget.subject.inMeasure(value, _unit);
    return amount == null || amount > widget.subject.leftQty + 0.1 ? null : amount;
  }

  void _selectUnit(StockMeasure aUnit)
  {
    final subject = widget.subject;
    final current = parseAmountText(_qtyCtrl.text);
    final pack = subject.packSize;
    setState(()
    {
      if (current != null && pack != null && aUnit != _unit)
      {
        final converted = aUnit == StockMeasure.pcs ? current / pack : current * pack;
        _qtyCtrl.text = amountText(double.parse(converted.toStringAsFixed(aUnit == StockMeasure.pcs ? 2 : 1)));
      }
      _unit = aUnit;
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final subject = widget.subject;
    final amount = _amount;
    final cost = subject.cost;
    final currCode = subject.currCode;
    final share = amount == null || cost == null || currCode == null || subject.totalQty <= 0 ? null : cost * amount / subject.totalQty;
    final pieces = subject.packSize == null ? null : subject.leftQty / subject.packSize!;

    return AlertDialog(
      scrollable: true,
      title: Text('stock.writeoff_title'.tr(args: [subject.title])),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final unit in subject.units)
                  ChoiceChip(
                    key: ValueKey('writeoff.unit.${unit.name}'),
                    showCheckmark: false,
                    label: Text(measureLabel(unit)),
                    selected: _unit == unit,
                    onSelected: (_) => _selectUnit(unit),
                  ),
                if (subject.isUnmeasured && widget.canAskPack)
                  ActionChip(
                    key: const ValueKey('writeoff.ask_pack'),
                    avatar: const Icon(AppIcons.scale, size: 16),
                    label: Text('stock.writeoff_in_grams'.tr()),
                    onPressed: () => Navigator.of(aContext).pop(const WriteOffDraft.packRequested()),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('writeoff.qty'),
              controller: _qtyCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(_numberInput), LengthLimitingTextInputFormatter(9)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'stock.waste_qty'.tr(),
                suffixText: measureLabel(_unit),
                helperText: 'stock.left_of'.tr(args: [formatStockAmount(aContext, subject.leftQty, subject.measure, aPieces: pieces)]),
                helperMaxLines: 2,
                errorText: _qtyCtrl.text.trim().isEmpty || amount != null ? null : 'stock.err_waste_qty'.tr(),
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
                for (final reason in writeOffReasons)
                  ChoiceChip(
                    key: ValueKey('writeoff.reason.${reason?.name ?? 'used'}'),
                    showCheckmark: false,
                    label: Text(writeOffReasonLabel(reason)),
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
            if (share != null && currCode != null && _reason != null)
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
          key: const ValueKey('writeoff.save'),
          onPressed: amount == null
              ? null
              : () => Navigator.of(aContext).pop(WriteOffDraft(
                    qty: parseAmountText(_qtyCtrl.text)!,
                    unit: _unit,
                    reason: _reason,
                    note: _noteCtrl.text.trim(),
                  )),
          child: Text('stock.writeoff_action'.tr()),
        ),
      ],
    );
  }
}

class PackMass
{
  final double qty;
  final NetMeasure measure;

  const PackMass(this.qty, this.measure);
}

Future<PackMass?> showPackMassDialog(BuildContext aContext, String aTitle, {String? aReason})
{
  return showDialog<PackMass>(context: aContext, builder: (_) => PackMassDialog(title: aTitle, reason: aReason));
}

class PackMassDialog extends StatefulWidget
{
  final String title;
  final String? reason;

  const PackMassDialog({super.key, required this.title, this.reason});

  @override
  State<PackMassDialog> createState() => _PackMassDialogState();
}

class _PackMassDialogState extends State<PackMassDialog>
{
  final _qtyCtrl = TextEditingController();
  NetMeasure _measure = NetMeasure.g;

  @override
  void dispose()
  {
    _qtyCtrl.dispose();
    super.dispose();
  }

  double? get _qty
  {
    final value = parseAmountText(_qtyCtrl.text);
    return value == null || value <= 0 || value > _maxLotQty ? null : value;
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final qty = _qty;

    return AlertDialog(
      scrollable: true,
      title: Text('stock.pack_title'.tr(args: [widget.title])),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.reason ?? 'stock.pack_hint'.tr(), style: TextStyle(color: palette.inkSecondary)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final measure in NetMeasure.values)
                  ChoiceChip(
                    key: ValueKey('pack.measure.${measure.name}'),
                    showCheckmark: false,
                    label: Text(measureLabel(measure == NetMeasure.ml ? StockMeasure.ml : StockMeasure.g)),
                    selected: _measure == measure,
                    onSelected: (_) => setState(() => _measure = measure),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('pack.qty'),
              controller: _qtyCtrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(_numberInput), LengthLimitingTextInputFormatter(9)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'stock.pack_qty'.tr(),
                suffixText: measureLabel(_measure == NetMeasure.ml ? StockMeasure.ml : StockMeasure.g),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('stock.pack_skip'.tr())),
        ElevatedButton(
          key: const ValueKey('pack.save'),
          onPressed: qty == null ? null : () => Navigator.of(aContext).pop(PackMass(qty, _measure)),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

DateTime _dayOf(DateTime aValue) => DateTime(aValue.year, aValue.month, aValue.day);

class ExpiryPicker extends StatelessWidget
{
  final DateTime? value;
  final DateTime firstDate;
  final ValueChanged<DateTime?> onChanged;

  const ExpiryPicker({super.key, required this.value, required this.firstDate, required this.onChanged});

  Future<void> _pick(BuildContext aContext) async
  {
    final today = _dayOf(DateTime.now());
    final first = _dayOf(firstDate);
    final last = today.add(const Duration(days: _maxShelfDays));
    final current = value;
    final picked = await showDatePicker(
      context: aContext,
      helpText: 'stock.expiry'.tr(),
      initialDate: current == null || current.isBefore(first) ? (today.isBefore(first) ? first : today) : current,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null)
    {
      onChanged(_dayOf(picked));
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final current = value;
    final today = _dayOf(DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ActionChip(
              key: const ValueKey('expiry.pick'),
              avatar: const Icon(AppIcons.hourglass, size: 16),
              label: Text(current == null
                  ? 'stock.expiry_none'.tr()
                  : 'stock.expires_on'.tr(args: [formatExpiryDate(aContext, current)])),
              onPressed: () => _pick(aContext),
            ),
            if (current != null)
              IconButton(
                key: const ValueKey('expiry.clear'),
                tooltip: 'stock.expiry_clear'.tr(),
                visualDensity: VisualDensity.compact,
                icon: const Icon(AppIcons.x, size: 18),
                onPressed: () => onChanged(null),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final days in _quickShelfDays)
              ChoiceChip(
                key: ValueKey('expiry.plus.$days'),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                label: Text('stock.expiry_plus_days'.tr(args: ['$days'])),
                selected: current != null && current == today.add(Duration(days: days)),
                onSelected: (_) => onChanged(today.add(Duration(days: days))),
              ),
          ],
        ),
      ],
    );
  }
}

class ExpiryChoice
{
  final DateTime? expiresOn;

  const ExpiryChoice(this.expiresOn);
}

Future<ExpiryChoice?> showExpiryDialog(BuildContext aContext, StockLot aLot)
{
  return showDialog<ExpiryChoice>(context: aContext, builder: (_) => ExpiryDialog(lot: aLot));
}

class ExpiryDialog extends StatefulWidget
{
  final StockLot lot;

  const ExpiryDialog({super.key, required this.lot});

  @override
  State<ExpiryDialog> createState() => _ExpiryDialogState();
}

class _ExpiryDialogState extends State<ExpiryDialog>
{
  late DateTime? _expiresOn = widget.lot.expiresOn;

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final today = _dayOf(DateTime.now());
    final expiresOn = _expiresOn;
    final isPast = expiresOn != null && expiresOn.isBefore(today);

    return AlertDialog(
      scrollable: true,
      title: Text('stock.expiry_title'.tr(args: [widget.lot.title])),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpiryPicker(
              value: expiresOn,
              firstDate: widget.lot.acquiredTs,
              onChanged: (aValue) => setState(() => _expiresOn = aValue),
            ),
            const SizedBox(height: 10),
            Text(
              isPast ? 'stock.expiry_past_hint'.tr() : 'stock.expiry_hint'.tr(),
              style: TextStyle(fontSize: 12, color: isPast ? palette.danger : palette.inkMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('expiry.save'),
          onPressed: () => Navigator.of(aContext).pop(ExpiryChoice(_expiresOn)),
          child: Text('common.save'.tr()),
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
  final DateTime? expiresOn;

  const LotDraft({required this.qty, required this.unit, this.cost, this.currId, required this.acquiredOn, this.expiresOn});
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
  DateTime? _expiresOn;

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
                  const SizedBox(height: 12),
                  Text('stock.expiry'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
                  const SizedBox(height: 6),
                  ExpiryPicker(
                    value: _expiresOn,
                    firstDate: DateTime.now(),
                    onChanged: (aValue) => setState(() => _expiresOn = aValue),
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
                    expiresOn: _expiresOn,
                  ))
              : null,
          child: Text('stock.add_to_stock'.tr()),
        ),
      ],
    );
  }
}
