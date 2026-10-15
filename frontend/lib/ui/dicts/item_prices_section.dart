import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'item_form.dart';
import '../common/app_theme.dart';

const String _isConvertPref = 'items.is_convert';
const String _convertToPref = 'items.convert_to';
const String _defaultConvertCode = 'UAH';

class ItemPricesSection extends ConsumerStatefulWidget
{
  final DictItemDto item;

  const ItemPricesSection({super.key, required this.item});

  @override
  ConsumerState<ItemPricesSection> createState() => _ItemPricesSectionState();
}

class _ItemPricesSectionState extends ConsumerState<ItemPricesSection>
{
  ItemPricesData? _data;
  List<ManualPriceDto> _manual = const [];
  List<CurrencyDto> _currencies = const [];
  List<PlaceDto> _places = const [];
  bool _isConverting = false;
  String _convertCode = _defaultConvertCode;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _init();
  }

  Future<SharedPreferences?> _prefs() async
  {
    try
    {
      return await SharedPreferences.getInstance();
    }
    on Exception
    {
      return null;
    }
  }

  Future<void> _init() async
  {
    final prefs = await _prefs();
    _isConverting = prefs?.getBool(_isConvertPref) ?? false;
    _convertCode = prefs?.getString(_convertToPref) ?? _defaultConvertCode;
    try
    {
      final api = ref.read(apiProv);
      final currencies = await api.getCurrencies();
      final places = await api.getPlaces();
      if (mounted)
      {
        setState(()
        {
          _currencies = currencies;
          _places = places;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
    await _load();
  }

  Future<void> _load() async
  {
    try
    {
      final api = ref.read(apiProv);
      final data = await api.getItemPrices(widget.item.id, aConvertTo: _isConverting ? _convertCode : null);
      final manual = await api.getManualPrices(widget.item.id);
      if (mounted)
      {
        setState(()
        {
          _data = data;
          _manual = manual;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  Future<void> _setConversion(bool aIsConverting, String aCode) async
  {
    setState(()
    {
      _isConverting = aIsConverting;
      _convertCode = aCode;
    });
    final prefs = await _prefs();
    await prefs?.setBool(_isConvertPref, aIsConverting);
    await prefs?.setString(_convertToPref, aCode);
    await _load();
  }

  Future<void> _addManualPrice() async
  {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ManualPriceDialog(
        places: _places,
        currencies: _currencies,
        unit: widget.item.unit,
        defaultCode: _convertCode,
      ),
    );
    if (payload == null || !mounted)
    {
      return;
    }

    try
    {
      await ref.read(apiProv).addManualPrice(widget.item.id, payload);
      await _load();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  Future<void> _deleteManualPrice(ManualPriceDto aPrice) async
  {
    try
    {
      await ref.read(apiProv).deleteManualPrice(widget.item.id, aPrice.id);
      await _load();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final data = _data;
    final unit = widget.item.unit;
    final codes = {_defaultConvertCode, 'EUR', 'USD', ..._currencies.map((aCurrency) => aCurrency.code)}.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('items.prices'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('items.prices_hint'.tr(args: [itemUnitShort(unit)]), style: TextStyle(color: context.palette.inkSecondary)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(value: _isConverting, onChanged: (aValue) => _setConversion(aValue ?? false, _convertCode)),
                GestureDetector(
                  onTap: () => _setConversion(!_isConverting, _convertCode),
                  child: Text('finance.convert_to'.tr()),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: codes.contains(_convertCode) ? _convertCode : _defaultConvertCode,
                  isDense: true,
                  items: codes.map((aCode) => DropdownMenuItem(value: aCode, child: Text(aCode))).toList(),
                  onChanged: (aValue) => _setConversion(true, aValue ?? _defaultConvertCode),
                ),
              ],
            ),
            OutlinedButton.icon(
              onPressed: _currencies.isEmpty ? null : _addManualPrice,
              icon: const Icon(AppIcons.tag, size: 16),
              label: Text('items.add_price'.tr()),
            ),
          ],
        ),
        if (data != null && data.matchedItems > 1) ...[
          const SizedBox(height: 8),
          _Note(icon: AppIcons.scanBarcode, text: 'items.matched_by_barcode'.tr(args: ['${data.matchedItems}'])),
        ],
        if (widget.item.familyId != null) ...[
          const SizedBox(height: 8),
          _Note(icon: AppIcons.users, text: 'items.family_prices_hint'.tr()),
        ],
        if (data != null && data.missingRates.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'finance.missing_rates'.tr(args: [data.missingRates.join(', ')]),
            style: TextStyle(fontSize: 12, color: context.palette.warning),
          ),
        ],
        const SizedBox(height: 12),
        if (_error != null)
          ErrorRetry(error: _error!, onRetry: _load)
        else if (data == null)
          const LinearProgressIndicator()
        else if (data.prices.isEmpty)
          Text('items.no_prices'.tr(), style: TextStyle(color: context.palette.inkMuted))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(children: _buildPriceRows(data.prices)),
          ),
        if (_manual.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text('items.my_prices'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: _manual.map((aPrice) => _ManualPriceTile(
                    price: aPrice,
                    unit: unit,
                    onDelete: () => _deleteManualPrice(aPrice),
                  )).toList(),
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _buildPriceRows(List<ItemPriceDto> aPrices)
  {
    final cheapest = <String, double>{};
    final storeCounts = <String, int>{};
    for (final price in aPrices)
    {
      final current = cheapest[price.currCode];
      cheapest[price.currCode] = current == null || price.lastPrice < current ? price.lastPrice : current;
      storeCounts.update(price.currCode, (aCount) => aCount + 1, ifAbsent: () => 1);
    }

    return aPrices.map((aPrice)
    {
      final isCheapest = (storeCounts[aPrice.currCode] ?? 0) > 1 && aPrice.lastPrice == cheapest[aPrice.currCode];
      return _PriceRow(price: aPrice, unit: widget.item.unit, isCheapest: isCheapest);
    }).toList();
  }
}

class _Note extends StatelessWidget
{
  final IconData icon;
  final String text;

  const _Note({required this.icon, required this.text});

  @override
  Widget build(BuildContext aContext)
  {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: aContext.palette.inkMuted),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: aContext.palette.inkSecondary))),
      ],
    );
  }
}

class _PriceRow extends StatelessWidget
{
  final ItemPriceDto price;
  final ItemUnit unit;
  final bool isCheapest;

  const _PriceRow({required this.price, required this.unit, required this.isCheapest});

  @override
  Widget build(BuildContext aContext)
  {
    final perUnit = ' / ${itemUnitShort(unit)}';
    final details = [
      if (price.branch != null) price.branch!,
      '${'items.min'.tr()} ${formatMoney(aContext, price.minPrice, price.currCode)}',
      '${'items.avg'.tr()} ${formatMoney(aContext, price.avgPrice, price.currCode)}',
      'items.observations'.tr(args: ['${price.count}']),
      formatDate(aContext, price.lastTs),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCheapest ? BorderSide(color: aContext.palette.positive) : BorderSide.none,
      ),
      child: ListTile(
        leading: Icon(AppIcons.store, color: aContext.palette.inkSecondary),
        title: Row(
          children: [
            Flexible(
              child: Text(
                price.storeName ?? 'items.no_merchant'.tr(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (price.isShared) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'items.shared_prices_hint'.tr(),
                child: Icon(AppIcons.users, size: 14, color: aContext.palette.inkMuted),
              ),
            ],
          ],
        ),
        subtitle: Text(details),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${formatMoney(aContext, price.lastPrice, price.currCode)}$perUnit',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: aContext.palette.inkPrimary),
            ),
            if (isCheapest)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppIcons.checkCircle, size: 14, color: aContext.palette.positive),
                  const SizedBox(width: 4),
                  Text('items.cheapest'.tr(), style: TextStyle(fontSize: 12, color: aContext.palette.positive)),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ManualPriceTile extends StatelessWidget
{
  final ManualPriceDto price;
  final ItemUnit unit;
  final VoidCallback onDelete;

  const _ManualPriceTile({required this.price, required this.unit, required this.onDelete});

  @override
  Widget build(BuildContext aContext)
  {
    final qty = NumberFormat.decimalPattern(aContext.locale.toLanguageTag()).format(price.qty);
    final details = [
      if (price.branch != null) price.branch!,
      '${formatMoney(aContext, price.price, price.currCode)} · $qty ${itemUnitShort(unit)}',
      formatDate(aContext, price.seenTs),
      if (price.note != null) price.note!,
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(AppIcons.tag, color: aContext.palette.inkMuted),
      title: Text(price.storeName ?? 'items.no_merchant'.tr()),
      subtitle: Text(details),
      trailing: IconButton(
        tooltip: 'common.delete'.tr(),
        icon: const Icon(AppIcons.trash2, size: 18),
        onPressed: onDelete,
      ),
    );
  }
}

class _ManualPriceDialog extends StatefulWidget
{
  final List<PlaceDto> places;
  final List<CurrencyDto> currencies;
  final ItemUnit unit;
  final String defaultCode;

  const _ManualPriceDialog({
    required this.places,
    required this.currencies,
    required this.unit,
    required this.defaultCode,
  });

  @override
  State<_ManualPriceDialog> createState() => _ManualPriceDialogState();
}

class _ManualPriceDialogState extends State<_ManualPriceDialog>
{
  final _storeCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String? _placeId;
  String? _addrId;
  late String? _currId = (widget.currencies.where((aCurrency) => aCurrency.code == widget.defaultCode).firstOrNull ??
          widget.currencies.firstOrNull)
      ?.id;
  DateTime _seenDay = DateTime.now();

  PlaceDto? get _place => widget.places.where((aPlace) => aPlace.id == _placeId).firstOrNull;

  @override
  void dispose()
  {
    _storeCtrl.dispose();
    _priceCtrl.dispose();
    _qtyCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async
  {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _seenDay,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null)
    {
      setState(() => _seenDay = picked);
    }
  }

  void _submit()
  {
    final price = parseAmountInput(_priceCtrl.text);
    final qtyText = _qtyCtrl.text.trim().replaceAll(',', '.');
    final qty = qtyText.isEmpty ? 1.0 : double.tryParse(qtyText);
    final storeName = _storeCtrl.text.trim();

    if (price == null || price < 0)
    {
      showInfoSnack(context, 'items.err_price'.tr());
      return;
    }
    if (qty == null || qty <= 0)
    {
      showInfoSnack(context, 'items.err_qty'.tr());
      return;
    }
    if (_placeId == null && storeName.isEmpty)
    {
      showInfoSnack(context, 'items.err_store'.tr());
      return;
    }

    final now = DateTime.now();
    final isToday = _seenDay.year == now.year && _seenDay.month == now.month && _seenDay.day == now.day;
    final seenTs = isToday ? now : DateTime(_seenDay.year, _seenDay.month, _seenDay.day, 12);

    Navigator.of(context).pop(<String, dynamic>{
      if (_placeId != null) 'place_id': _placeId,
      if (_placeId != null && _addrId != null) 'place_addr_id': _addrId,
      if (_placeId == null) 'merchant_name': storeName,
      'curr_id': _currId,
      'qty': qty.toStringAsFixed(3),
      'price': price.toStringAsFixed(2),
      'seen_ts': seenTs.toUtc().toIso8601String(),
      if (_noteCtrl.text.trim().isNotEmpty) 'note': _noteCtrl.text.trim(),
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    final addrs = _place?.addrs ?? const <PlaceAddrDto>[];

    return AlertDialog(
      title: Text('items.add_price'.tr()),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String?>(
                initialValue: _placeId,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'items.store'.tr(), border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text('items.store_other'.tr())),
                  ...widget.places.map((aPlace) => DropdownMenuItem<String?>(
                        value: aPlace.id,
                        child: Text(
                          aPlace.familyName == null ? aPlace.name : '${aPlace.name} · ${aPlace.familyName}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      )),
                ],
                onChanged: (aValue) => setState(()
                {
                  _placeId = aValue;
                  _addrId = null;
                }),
              ),
              const SizedBox(height: 12),
              if (_placeId == null)
                TextField(
                  controller: _storeCtrl,
                  inputFormatters: [LengthLimitingTextInputFormatter(100)],
                  decoration: InputDecoration(labelText: 'items.store_name'.tr(), border: const OutlineInputBorder()),
                )
              else if (addrs.isNotEmpty)
                DropdownButtonFormField<String?>(
                  key: ValueKey(_placeId),
                  initialValue: _addrId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: 'catalog.branch'.tr(), border: const OutlineInputBorder()),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('catalog.branch_any'.tr())),
                    ...addrs.map((aAddr) => DropdownMenuItem<String?>(
                          value: aAddr.id,
                          child: Text(aAddr.label ?? '', overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (aValue) => setState(() => _addrId = aValue),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _priceCtrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'items.price'.tr(), border: const OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 110,
                    child: DropdownButtonFormField<String>(
                      initialValue: _currId,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: 'wallet.currency'.tr(), border: const OutlineInputBorder()),
                      items: widget.currencies
                          .map((aCurrency) => DropdownMenuItem(value: aCurrency.id, child: Text(aCurrency.code)))
                          .toList(),
                      onChanged: (aValue) => setState(() => _currId = aValue),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _qtyCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'items.price_qty'.tr(),
                  hintText: '1',
                  suffixText: itemUnitShort(widget.unit),
                  helperText: 'items.price_qty_hint'.tr(),
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickDay,
                icon: const Icon(AppIcons.calendar, size: 16),
                label: Text(formatDate(aContext, _seenDay)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                decoration: InputDecoration(labelText: 'routine.note'.tr(), border: const OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: _currId == null ? null : _submit, child: Text('common.save'.tr())),
      ],
    );
  }
}
