import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'finance_dialogs.dart';
import 'transactions_screen.dart';

class ReceiptDetailScreen extends ConsumerStatefulWidget
{
  final String? receiptId;
  final TxDto? initialTx;

  const ReceiptDetailScreen({super.key, this.receiptId, this.initialTx});

  @override
  ConsumerState<ReceiptDetailScreen> createState() => _ReceiptDetailScreenState();
}

class _ItemRow
{
  final nameCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
  final amountCtrl = TextEditingController();
  final Key key = UniqueKey();

  _ItemRow();

  _ItemRow.from(ReceiptItem aItem)
  {
    nameCtrl.text = aItem.name;
    qtyCtrl.text = _trimZeros(aItem.qty);
    priceCtrl.text = aItem.unitPrice == null ? '' : aItem.unitPrice!.toStringAsFixed(2);
    amountCtrl.text = aItem.amount.toStringAsFixed(2);
  }

  static String _trimZeros(double aValue) =>
      aValue == aValue.roundToDouble() ? aValue.toStringAsFixed(0) : aValue.toString();

  double get amount => parseAmountInput(amountCtrl.text) ?? 0;

  double get qty => double.tryParse(qtyCtrl.text.replaceAll(',', '.')) ?? 1;

  void recalc()
  {
    final price = parseAmountInput(priceCtrl.text);
    if (price != null)
    {
      amountCtrl.text = (qty * price).toStringAsFixed(2);
    }
  }

  void dispose()
  {
    nameCtrl.dispose();
    qtyCtrl.dispose();
    priceCtrl.dispose();
    amountCtrl.dispose();
  }
}

class _ReceiptDetailScreenState extends ConsumerState<ReceiptDetailScreen>
{
  final _merchantCtrl = TextEditingController();
  final _merchantFocus = FocusNode();
  final _noteCtrl = TextEditingController();
  final List<_ItemRow> _rows = [];
  List<TxDto> _txs = [];
  List<CurrencyDto> _currs = const [];
  List<PlaceDto> _places = const [];
  ReceiptDto? _saved;
  String? _merchantId;
  String? _placeId;
  String? _currId;
  String? _cashAccountId;
  bool _isCashChosen = false;
  DateTime _ts = DateTime.now();
  Object? _loadError;
  bool _isLoading = true;
  bool _isSaving = false;

  bool get _isEdit => widget.receiptId != null;

  String get _currCode => _currs.where((aCurr) => aCurr.id == _currId).firstOrNull?.code ?? '';

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _merchantCtrl.dispose();
    _merchantFocus.dispose();
    _noteCtrl.dispose();
    for (final row in _rows)
    {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async
  {
    try
    {
      final api = ref.read(apiProv);
      final currs = await api.getCurrencies();
      final places = await api.getPlaces();
      final receipt = _isEdit ? await api.getReceipt(widget.receiptId!) : null;

      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _currs = currs;
        _places = places;
        if (receipt != null)
        {
          _apply(receipt);
        }
        else
        {
          final tx = widget.initialTx;
          _txs = tx == null ? [] : [tx];
          _ts = tx?.txTs ?? DateTime.now();
          _merchantCtrl.text = tx?.merchantName ?? tx?.counterparty ?? '';
          _merchantId = tx?.merchantId;
          _currId = currs.where((aCurr) => aCurr.code == tx?.currCode).firstOrNull?.id ?? _defaultCurrency(currs);
          _rows.add(_ItemRow());
        }
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isLoading = false);
      }
    }
  }

  String? _defaultCurrency(List<CurrencyDto> aCurrs)
  {
    final wallets = ref.read(walletsProv).valueOrNull ?? const <AccountDto>[];
    final preferred = wallets.where((aWallet) => aWallet.isCash).firstOrNull?.currId ?? wallets.firstOrNull?.currId;
    return preferred ?? aCurrs.firstOrNull?.id;
  }

  void _apply(ReceiptDto aReceipt)
  {
    _saved = aReceipt;
    _ts = aReceipt.receiptTs;
    _merchantCtrl.text = aReceipt.merchantName ?? '';
    _merchantId = aReceipt.merchantId;
    _placeId = aReceipt.placeId;
    _currId = aReceipt.currId;
    _cashAccountId = aReceipt.cashAccountId;
    _isCashChosen = true;
    _noteCtrl.text = aReceipt.note ?? '';
    _txs = [...aReceipt.txs];
    for (final row in _rows)
    {
      row.dispose();
    }
    _rows
      ..clear()
      ..addAll(aReceipt.items.map(_ItemRow.from));
    if (_rows.isEmpty)
    {
      _rows.add(_ItemRow());
    }
  }

  double _paidIn(TxDto aTx)
  {
    if (aTx.currCode == _currCode)
    {
      return -aTx.amount;
    }
    if (aTx.opCurrCode == _currCode && aTx.opAmount != null)
    {
      return -aTx.opAmount!;
    }
    return 0;
  }

  List<AccountDto> _cashWallets()
  {
    return (ref.read(walletsProv).valueOrNull ?? const <AccountDto>[])
        .where((aWallet) => aWallet.isCash && !aWallet.isLinked && aWallet.isEditable && aWallet.currId == _currId)
        .toList();
  }

  Future<void> _pickTransaction() async
  {
    final picked = await showDialog<TxDto>(
      context: context,
      builder: (_) => _TxPickerDialog(around: _ts, excluded: _txs.map((aTx) => aTx.id).toSet(), currCode: _currCode),
    );

    if (picked != null && mounted)
    {
      setState(() => _txs = [..._txs, picked]);
    }
  }

  Future<void> _save() async
  {
    final items = <Map<String, dynamic>>[];
    for (final row in _rows)
    {
      final name = row.nameCtrl.text.trim();
      final amount = parseAmountInput(row.amountCtrl.text);
      if (name.isEmpty && (amount == null || amount == 0))
      {
        continue;
      }
      if (name.isEmpty || amount == null || amount < 0)
      {
        showInfoSnack(context, 'finance.err_item'.tr());
        return;
      }

      final qty = row.qty;
      items.add(ReceiptItem(
        name: name,
        qty: qty <= 0 ? 1 : qty,
        unitPrice: parseAmountInput(row.priceCtrl.text),
        amount: amount,
      ).toJson());
    }

    final cashWallets = _cashWallets();
    final cashAccountId = _isCashChosen ? _cashAccountId : cashWallets.firstOrNull?.id;
    final merchantName = _merchantCtrl.text.trim();
    final note = _noteCtrl.text.trim();

    setState(() => _isSaving = true);

    try
    {
      final saved = await ref.read(apiProv).saveReceipt(widget.receiptId, {
        'receipt_ts': _ts.toUtc().toIso8601String(),
        'merchant_name': merchantName.isEmpty ? null : merchantName,
        'merchant_id': _merchantId,
        'place_id': _placeId,
        'curr_id': _currId,
        'cash_account_id': cashAccountId,
        'note': note.isEmpty ? null : note,
        'items': items,
        'tx_ids': _txs.map((aTx) => aTx.id).toList(),
      });

      ref.invalidate(receiptsProv);
      ref.invalidate(walletsProv);

      if (!mounted)
      {
        return;
      }

      showInfoSnack(context, 'common.saved'.tr());
      if (_isEdit)
      {
        setState(() => _apply(saved));
      }
      else
      {
        context.go('/app/receipts/${saved.id}');
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'finance.delete_receipt'.tr(),
      aMessage: 'finance.delete_receipt_confirm'.tr(),
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    try
    {
      await ref.read(apiProv).deleteReceipt(widget.receiptId!);
      ref.invalidate(receiptsProv);
      if (mounted)
      {
        context.go('/app/receipts');
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

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.watch(walletsProv);

    if (_isLoading)
    {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null)
    {
      return ErrorRetry(error: _loadError!, onRetry: _load);
    }

    final itemsTotal = _rows.fold<double>(0, (aSum, aRow) => aSum + aRow.amount);
    final paidTotal = _txs.fold<double>(0, (aSum, aTx) => aSum + _paidIn(aTx));
    final rest = paidTotal - itemsTotal;
    final cashWallets = _cashWallets();
    final effectiveCash = _isCashChosen ? _cashAccountId : cashWallets.firstOrNull?.id;

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'finance.receipt'.tr() : 'finance.new_receipt'.tr(),
          actions: [
            if (_isEdit)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(AppIcons.trash2, size: 18),
                label: Text('common.delete'.tr()),
              ),
            ElevatedButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(AppIcons.save, size: 18),
              label: Text('common.save'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(width: 320, child: _buildMerchantField()),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String?>(
                initialValue: _placeId,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'finance.place'.tr(), border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text('finance.no_place'.tr())),
                  ..._places.map((aPlace) => DropdownMenuItem<String?>(value: aPlace.id, child: Text(aPlace.name))),
                ],
                onChanged: (aValue) => setState(() => _placeId = aValue),
              ),
            ),
            SizedBox(width: 240, child: DateTimeField(value: _ts, onChanged: (aValue) => setState(() => _ts = aValue))),
            SizedBox(
              width: 140,
              child: DropdownButtonFormField<String>(
                initialValue: _currId,
                decoration: InputDecoration(labelText: 'wallet.currency'.tr(), border: const OutlineInputBorder()),
                items: _currs.map((aCurr) => DropdownMenuItem(value: aCurr.id, child: Text(aCurr.code))).toList(),
                onChanged: (aValue) => setState(()
                {
                  _currId = aValue;
                  _isCashChosen = false;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Text('finance.items'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ..._rows.map(_buildItemRow),
        if (rest > 0.004) _buildVirtualRow(aContext, 'finance.rest'.tr(), rest, AppIcons.circleDot),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _rows.add(_ItemRow())),
            icon: const Icon(AppIcons.plus, size: 18),
            label: Text('finance.add_item'.tr()),
          ),
        ),
        const SizedBox(height: 24),
        Text('finance.payments'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ..._txs.map((aTx) => TxTile(
              tx: aTx,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(formatMoney(aContext, aTx.amount, aTx.currCode), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  IconButton(
                    tooltip: 'finance.unlink'.tr(),
                    icon: const Icon(AppIcons.x, size: 18),
                    onPressed: () => setState(() => _txs = _txs.where((aItem) => aItem.id != aTx.id).toList()),
                  ),
                ],
              ),
            )),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _pickTransaction,
            icon: const Icon(AppIcons.link, size: 18),
            label: Text('finance.link_tx'.tr()),
          ),
        ),
        if (rest < -0.004) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(AppIcons.banknote, color: inkSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: ValueKey('cash-$_currId'),
                  initialValue: effectiveCash,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '${'finance.cash_rest'.tr()}: ${formatMoney(aContext, -rest, _currCode)}',
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('finance.cash_not_tracked'.tr())),
                    ...cashWallets.map((aWallet) => DropdownMenuItem<String?>(value: aWallet.id, child: Text(aWallet.name))),
                  ],
                  onChanged: (aValue) => setState(()
                  {
                    _cashAccountId = aValue;
                    _isCashChosen = true;
                  }),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        _buildTotals(aContext, itemsTotal, paidTotal),
        const SizedBox(height: 24),
        TextField(
          controller: _noteCtrl,
          maxLines: 2,
          inputFormatters: [LengthLimitingTextInputFormatter(500)],
          decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
        ),
        if (_saved != null) const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildMerchantField()
  {
    return RawAutocomplete<MerchantDto>(
      textEditingController: _merchantCtrl,
      focusNode: _merchantFocus,
      displayStringForOption: (aMerchant) => aMerchant.name,
      optionsBuilder: (aValue) async
      {
        final query = aValue.text.trim();
        if (query.length < 2)
        {
          return const <MerchantDto>[];
        }
        try
        {
          return await ref.read(apiProv).getMerchants(query);
        }
        catch (_)
        {
          return const <MerchantDto>[];
        }
      },
      onSelected: (aMerchant) => setState(() => _merchantId = aMerchant.id),
      fieldViewBuilder: (aContext, aCtrl, aFocus, aOnSubmitted) => TextField(
        controller: aCtrl,
        focusNode: aFocus,
        inputFormatters: [LengthLimitingTextInputFormatter(100)],
        onChanged: (_) => _merchantId = null,
        decoration: InputDecoration(
          labelText: 'finance.merchant'.tr(),
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(AppIcons.shoppingBag),
        ),
      ),
      optionsViewBuilder: (aContext, aOnSelected, aOptions) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
            child: ListView(
              shrinkWrap: true,
              children: aOptions
                  .map((aMerchant) => ListTile(title: Text(aMerchant.name), onTap: () => aOnSelected(aMerchant)))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItemRow(_ItemRow aRow)
  {
    InputDecoration decoration(String aLabel) => InputDecoration(labelText: aLabel, border: const OutlineInputBorder(), isDense: true);

    return Padding(
      key: aRow.key,
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: TextField(
              controller: aRow.nameCtrl,
              inputFormatters: [LengthLimitingTextInputFormatter(200)],
              decoration: decoration('finance.item_name'.tr()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: aRow.qtyCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: amountFormatters,
              onChanged: (_) => setState(aRow.recalc),
              decoration: decoration('finance.qty'.tr()).copyWith(hintText: '1'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: aRow.priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: amountFormatters,
              onChanged: (_) => setState(aRow.recalc),
              decoration: decoration('finance.price'.tr()),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: aRow.amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: amountFormatters,
              onChanged: (_) => setState(() {}),
              decoration: decoration('finance.amount'.tr()),
            ),
          ),
          IconButton(
            tooltip: 'common.delete'.tr(),
            icon: const Icon(AppIcons.x, size: 18),
            onPressed: () => setState(()
            {
              _rows.remove(aRow);
              aRow.dispose();
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildVirtualRow(BuildContext aContext, String aLabel, double aAmount, IconData aIcon)
  {
    return Container(
      margin: const EdgeInsets.only(bottom: 8, right: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Icon(aIcon, size: 16, color: inkMuted),
          const SizedBox(width: 8),
          Expanded(child: Text(aLabel, style: const TextStyle(fontStyle: FontStyle.italic, color: inkSecondary))),
          Text(formatMoney(aContext, aAmount, _currCode), style: const TextStyle(color: inkSecondary)),
        ],
      ),
    );
  }

  Widget _buildTotals(BuildContext aContext, double aItemsTotal, double aPaidTotal)
  {
    Widget line(String aLabel, double aValue, {bool aIsBold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(aLabel, style: const TextStyle(color: inkSecondary))),
              Text(
                formatMoney(aContext, aValue, _currCode),
                style: TextStyle(fontWeight: aIsBold ? FontWeight.bold : FontWeight.w500, color: inkPrimary),
              ),
            ],
          ),
        );

    final total = aItemsTotal > aPaidTotal ? aItemsTotal : aPaidTotal;

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          line('finance.items_total'.tr(), aItemsTotal),
          line('finance.paid_by_tx'.tr(), aPaidTotal),
          if (aPaidTotal > aItemsTotal + 0.004) line('finance.rest'.tr(), aPaidTotal - aItemsTotal),
          if (aItemsTotal > aPaidTotal + 0.004) line('finance.cash_rest'.tr(), aItemsTotal - aPaidTotal),
          const Divider(),
          line('finance.receipt_total'.tr(), total, aIsBold: true),
        ],
      ),
    );
  }
}

class _TxPickerDialog extends ConsumerStatefulWidget
{
  final DateTime around;
  final Set<String> excluded;
  final String currCode;

  const _TxPickerDialog({required this.around, required this.excluded, required this.currCode});

  @override
  ConsumerState<_TxPickerDialog> createState() => _TxPickerDialogState();
}

class _TxPickerDialogState extends ConsumerState<_TxPickerDialog>
{
  List<TxDto>? _items;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    try
    {
      final page = await ref.read(apiProv).getTransactions(
            aFrom: widget.around.subtract(const Duration(days: 7)),
            aTo: widget.around.add(const Duration(days: 7)),
            aIsUnlinked: true,
            aLimit: 200,
          );
      if (mounted)
      {
        setState(() => _items = page.items
            .where((aTx) => !widget.excluded.contains(aTx.id) && aTx.isEditable)
            .where((aTx) => aTx.currCode == widget.currCode || aTx.opCurrCode == widget.currCode)
            .toList());
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

  @override
  Widget build(BuildContext aContext)
  {
    final items = _items;

    return AlertDialog(
      title: Text('finance.link_tx'.tr()),
      content: SizedBox(
        width: 520,
        height: 420,
        child: _error != null
            ? Center(child: Text(errorText(_error!)))
            : items == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(child: Text('finance.no_candidates'.tr(), style: const TextStyle(color: inkMuted)))
                    : ListView(
                        children: items
                            .map((aTx) => TxTile(tx: aTx, onTap: () => Navigator.of(aContext).pop(aTx)))
                            .toList(),
                      ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
      ],
    );
  }
}
