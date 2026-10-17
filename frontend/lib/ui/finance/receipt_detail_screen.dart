import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/ai_photo.dart';
import '../common/app_icons.dart';
import '../common/barcode_scanner.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/money.dart';
import '../dicts/item_form.dart';
import '../dicts/scope_widgets.dart';
import 'finance_dialogs.dart';
import 'receipt_view.dart';
import 'transactions_screen.dart';
import '../common/app_theme.dart';

class ReceiptDetailScreen extends ConsumerStatefulWidget
{
  final String? receiptId;
  final TxDto? initialTx;
  final ReceiptPrefill? prefill;

  const ReceiptDetailScreen({super.key, this.receiptId, this.initialTx, this.prefill});

  @override
  ConsumerState<ReceiptDetailScreen> createState() => _ReceiptDetailScreenState();
}

const String _fallbackCurrencyCode = 'UAH';
const double _wideRowWidth = 640;
const String _aiConsentPref = 'receipt.ai_consent';
const double _photoMaxSide = 2000;
const int _photoQuality = 85;

class _ItemChoice
{
  final DictItemDto? item;
  final String newName;

  const _ItemChoice.existing(DictItemDto this.item) : newName = '';

  const _ItemChoice.create(this.newName) : item = null;

  String get label => item?.name ?? newName;
}

class _ItemRow
{
  final nameCtrl = TextEditingController();
  final nameFocus = FocusNode();
  final qtyCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
  final priceFocus = FocusNode();
  final amountCtrl = TextEditingController();
  final Key key = UniqueKey();
  String? itemId;
  String itemName = '';
  ItemKind kind = ItemKind.product;
  ItemUnit unit = ItemUnit.piece;
  NewItemDraft? newItem;
  String? sourceText;
  LineMatch? match;
  bool isPricePrefilled = false;

  _ItemRow();

  _ItemRow.recognized(RecognizedLine aLine)
  {
    itemId = aLine.itemId;
    itemName = aLine.itemName ?? aLine.name;
    kind = aLine.kind;
    unit = aLine.unit;
    sourceText = aLine.text;
    match = aLine.match;
    if (aLine.itemId == null)
    {
      newItem = NewItemDraft(name: aLine.name, kind: aLine.kind, unit: aLine.unit, barcode: aLine.barcode);
    }
    nameCtrl.text = itemName;
    qtyCtrl.text = _trimZeros(aLine.qty);
    priceCtrl.text = aLine.unitPrice == null ? '' : aLine.unitPrice!.toStringAsFixed(2);
    amountCtrl.text = aLine.amount.toStringAsFixed(2);
  }

  _ItemRow.from(ReceiptItem aItem)
  {
    itemId = aItem.itemId;
    itemName = aItem.name;
    kind = aItem.kind;
    unit = aItem.unit;
    nameCtrl.text = aItem.name;
    qtyCtrl.text = _trimZeros(aItem.qty);
    priceCtrl.text = aItem.unitPrice == null ? '' : aItem.unitPrice!.toStringAsFixed(2);
    amountCtrl.text = aItem.amount.toStringAsFixed(2);
  }

  static String _trimZeros(double aValue) =>
      aValue == aValue.roundToDouble() ? aValue.toStringAsFixed(0) : aValue.toString();

  double get amount => parseAmountInput(amountCtrl.text) ?? 0;

  double get qty => double.tryParse(qtyCtrl.text.replaceAll(',', '.')) ?? 1;

  bool get isPicked => itemId != null;

  bool get isNew => itemId == null && newItem != null;

  bool get isBlank => nameCtrl.text.trim().isEmpty && (parseAmountInput(amountCtrl.text) ?? 0) == 0;

  void select(DictItemDto aItem)
  {
    if (itemId != aItem.id && isPricePrefilled)
    {
      priceCtrl.clear();
      isPricePrefilled = false;
    }
    itemId = aItem.id;
    newItem = null;
    match = null;
    itemName = aItem.name;
    kind = aItem.kind;
    unit = aItem.unit;
    if (nameCtrl.text != aItem.name)
    {
      nameCtrl.text = aItem.name;
    }
  }

  void onNameEdited(String aText)
  {
    if (aText.trim() != itemName)
    {
      itemId = null;
      newItem = null;
      match = null;
    }
  }

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
    nameFocus.dispose();
    qtyCtrl.dispose();
    priceCtrl.dispose();
    priceFocus.dispose();
    amountCtrl.dispose();
  }
}

class _ReceiptDetailScreenState extends ConsumerState<ReceiptDetailScreen>
{
  final _merchantCtrl = TextEditingController();
  final _merchantFocus = FocusNode();
  final _noteCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  final List<_ItemRow> _rows = [];
  List<TxDto> _txs = [];
  List<CurrencyDto> _currs = const [];
  List<PlaceDto> _places = const [];
  ReceiptDto? _saved;
  String? _merchantId;
  String? _placeId;
  String? _placeAddrId;
  NewPlaceDraft? _newPlace;
  String? _currId;
  String? _cashAccountId;
  String? _recognitionNote;
  bool _isCashChosen = false;
  DateTime _ts = DateTime.now();
  Object? _loadError;
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isStocked = true;

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
    _discountCtrl.dispose();
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
      final wallets = _isEdit ? const <AccountDto>[] : await api.getWallets();
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
          _placeId = places.any((aPlace) => aPlace.id == tx?.placeId) ? tx?.placeId : null;
          _placeAddrId = _placeId == null ? null : tx?.placeAddrId;
          _currId = currs.where((aCurr) => aCurr.code == tx?.currCode).firstOrNull?.id ?? _defaultCurrency(currs, wallets);
          final prefill = widget.prefill;
          if (prefill != null)
          {
            _ts = prefill.ts;
            _currId = prefill.currId;
            _cashAccountId = prefill.cashAccountId;
            _isCashChosen = true;
          }
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

  String? _defaultCurrency(List<CurrencyDto> aCurrs, List<AccountDto> aWallets)
  {
    final preferred = aWallets.where((aWallet) => aWallet.isCash).firstOrNull?.currId ?? aWallets.firstOrNull?.currId;
    final local = aCurrs.where((aCurr) => aCurr.code == _fallbackCurrencyCode).firstOrNull?.id;
    return preferred ?? local ?? aCurrs.firstOrNull?.id;
  }

  void _apply(ReceiptDto aReceipt)
  {
    _saved = aReceipt;
    _ts = aReceipt.receiptTs;
    _merchantCtrl.text = aReceipt.merchantName ?? '';
    _merchantId = aReceipt.merchantId;
    _placeId = aReceipt.placeId;
    _placeAddrId = aReceipt.placeAddrId;
    _currId = aReceipt.currId;
    _cashAccountId = aReceipt.cashAccountId;
    _isCashChosen = true;
    _noteCtrl.text = aReceipt.note ?? '';
    _isStocked = aReceipt.isStocked;
    _discountCtrl.text = _discountText(aReceipt.discount);
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

  String _discountText(double aValue) => aValue > 0.004 ? aValue.toStringAsFixed(2) : '';

  double get _discount => (parseAmountInput(_discountCtrl.text) ?? 0).clamp(0, double.infinity).toDouble();

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
    final familyId = defaultFamilyId(ref.read(famsProv).valueOrNull);
    final items = <Map<String, dynamic>>[];
    for (final row in _rows)
    {
      if (row.isBlank)
      {
        continue;
      }

      final amount = parseAmountInput(row.amountCtrl.text);
      final itemId = row.itemId;
      final newItem = row.newItem;
      if ((itemId == null && newItem == null) || amount == null || amount < 0)
      {
        showInfoSnack(context, 'finance.err_item'.tr());
        return;
      }

      final qty = row.qty;
      final line = ReceiptItem(
        itemId: itemId ?? '',
        qty: qty <= 0 ? 1 : qty,
        unitPrice: parseAmountInput(row.priceCtrl.text),
        amount: amount,
      ).toJson();
      if (itemId == null)
      {
        line
          ..remove('item_id')
          ..['new_item'] = newItem!.toJson();
      }
      if (row.sourceText != null)
      {
        line['source_text'] = row.sourceText;
      }
      items.add(line);
    }

    final itemsTotal = _rows.fold<double>(0, (aSum, aRow) => aSum + aRow.amount);
    final discount = _discount;
    if (discount > itemsTotal + 0.004)
    {
      showInfoSnack(context, 'finance.err_discount'.tr());
      return;
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
        'place_addr_id': _placeId == null ? null : _placeAddrId,
        'curr_id': _currId,
        'cash_account_id': cashAccountId,
        'note': note.isEmpty ? null : note,
        'items': items,
        'tx_ids': _txs.map((aTx) => aTx.id).toList(),
        'discount': moneyWire(discount),
        'is_stocked': _isStocked,
        if (_pendingPlace() != null) 'new_place': {..._pendingPlace()!.toJson(), 'family_id': familyId},
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
      else if (widget.prefill != null && context.canPop())
      {
        context.pop(true);
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
        finishPage(context, '/app/receipts');
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
    ref.watch(famsProv);

    if (_isLoading)
    {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null)
    {
      return ErrorRetry(error: _loadError!, onRetry: _load);
    }

    final saved = _saved;
    if (saved != null && !saved.isEditable)
    {
      return ReceiptView(receipt: saved);
    }

    final itemsTotal = _rows.fold<double>(0, (aSum, aRow) => aSum + aRow.amount);
    final discount = _discount;
    final paidTotal = _txs.fold<double>(0, (aSum, aTx) => aSum + _paidIn(aTx));
    final rest = paidTotal - (itemsTotal - discount);
    final cashWallets = _cashWallets();
    final effectiveCash = _isCashChosen ? _cashAccountId : cashWallets.firstOrNull?.id;

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'finance.receipt'.tr() : 'finance.new_receipt'.tr(),
          actions: [
            if (ref.watch(aiFeaturesProv).valueOrNull?.isReceiptRecognition ?? false)
              OutlinedButton.icon(
                onPressed: _isSaving ? null : _chooseRecognitionSource,
                icon: const Icon(AppIcons.camera, size: 18),
                label: Text('receipt.recognize'.tr()),
              ),
            if (_isEdit)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: context.palette.danger),
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
                key: ValueKey('place:$_placeId'),
                initialValue: _placeId,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'finance.place'.tr(), border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem<String?>(value: null, child: Text('finance.no_place'.tr())),
                  ..._placeOptions().map((aPlace) => DropdownMenuItem<String?>(
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
                  _placeAddrId = _branchesOf(aValue).length == 1 ? _branchesOf(aValue).first.id : null;
                  if (_newPlace?.placeId != aValue)
                  {
                    _newPlace = null;
                  }
                }),
              ),
            ),
            if (_branchesOf(_placeId).isNotEmpty)
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String?>(
                  key: ValueKey('branch:$_placeId:$_placeAddrId'),
                  initialValue: _placeAddrId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: 'catalog.branch'.tr(), border: const OutlineInputBorder()),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('catalog.branch_any'.tr())),
                    ..._branchesOf(_placeId).map((aAddr) => DropdownMenuItem<String?>(
                          value: aAddr.id,
                          child: Text(aAddr.label ?? '', overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: (aValue) => setState(() => _placeAddrId = aValue),
                ),
              ),
            SizedBox(width: 240, child: DateTimeField(value: _ts, onChanged: (aValue) => setState(() => _ts = aValue))),
            SizedBox(
              width: 140,
              child: DropdownButtonFormField<String>(
                key: ValueKey('curr:$_currId'),
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
        if (_pendingPlace() != null) ...[
          const SizedBox(height: 12),
          InputChip(
            avatar: const Icon(AppIcons.store, size: 16),
            label: Text(_pendingPlaceLabel(_pendingPlace()!)),
            onDeleted: () => setState(() => _newPlace = null),
          ),
        ],
        if (_recognitionNote != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: context.colors.primaryContainer, borderRadius: BorderRadius.circular(8)),
            child: Row(
              children: [
                Icon(AppIcons.checkCircle, size: 18, color: context.colors.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(_recognitionNote!, style: TextStyle(color: context.palette.inkPrimary))),
                IconButton(
                  tooltip: 'common.cancel'.tr(),
                  icon: const Icon(AppIcons.x, size: 16),
                  onPressed: () => setState(() => _recognitionNote = null),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 32),
        Text('finance.items'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ..._rows.map(_buildItemRow),
        if (rest > 0.004) _buildVirtualRow(aContext, 'finance.rest'.tr(), rest, AppIcons.circleDot),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => setState(() => _rows.add(_ItemRow())),
              icon: const Icon(AppIcons.plus, size: 18),
              label: Text('finance.add_item'.tr()),
            ),
            TextButton.icon(
              onPressed: () => scanBarcodes(context, _addScanned),
              icon: const Icon(AppIcons.scanBarcode, size: 18),
              label: Text('scanner.scan_items'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 320,
            child: Semantics(
              container: true,
              child: TextField(
                controller: _discountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: amountFormatters,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'finance.receipt_discount'.tr(),
                  helperText: 'finance.receipt_discount_hint'.tr(),
                  helperMaxLines: 3,
                  prefixIcon: const Icon(AppIcons.tag, size: 18),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
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
              Icon(AppIcons.banknote, color: context.palette.inkSecondary),
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
        _buildTotals(aContext, itemsTotal, discount, paidTotal),
        const SizedBox(height: 24),
        TextField(
          controller: _noteCtrl,
          maxLines: 2,
          inputFormatters: [LengthLimitingTextInputFormatter(500)],
          decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const ValueKey('receipt.stocked'),
          contentPadding: EdgeInsets.zero,
          value: _isStocked,
          onChanged: (aValue) => setState(() => _isStocked = aValue),
          title: Text('stock.receipt_switch'.tr()),
          subtitle: Text(
            _saved != null && _saved!.isStocked && _saved!.stockedCount > 0
                ? 'stock.receipt_stocked'.plural(_saved!.stockedCount)
                : 'stock.receipt_switch_hint'.tr(),
            style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
          ),
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

  NewPlaceDraft? _pendingPlace()
  {
    final draft = _newPlace;
    if (draft == null)
    {
      return null;
    }
    final isNewPlace = !draft.isBranch && _placeId == null;
    final isNewBranch = draft.isBranch && draft.placeId == _placeId && _placeAddrId == null;
    return isNewPlace || isNewBranch ? draft : null;
  }

  String _pendingPlaceLabel(NewPlaceDraft aDraft)
  {
    if (aDraft.isBranch)
    {
      return 'receipt.new_branch'.tr(args: [aDraft.address]);
    }
    final description = [aDraft.name, aDraft.address].where((aPart) => aPart.isNotEmpty).join(', ');
    return 'receipt.new_place'.tr(args: [description]);
  }

  Future<void> _recognize(ImageSource aSource) async
  {
    final isAccepted = await confirmAiConsent(
      context,
      ref,
      aPrefKey: _aiConsentPref,
      aTitleKey: 'receipt.ai_title',
      aMessageKey: 'receipt.ai_consent',
    );
    if (!isAccepted || !mounted)
    {
      return;
    }

    final photo = await pickAiPhoto(context, aSource, aMaxSide: _photoMaxSide, aQuality: _photoQuality);
    if (photo == null || !mounted)
    {
      return;
    }

    final draft = await runWithProgress(
      context,
      'receipt.recognizing'.tr(),
      () => ref.read(apiProv).recognizeReceipt(photo.base64, photo.mediaType),
    );
    if (draft != null && mounted)
    {
      _applyDraft(draft);
    }
  }

  void _applyDraft(RecognizedReceipt aDraft)
  {
    final currCode = aDraft.currCode ?? _currCode;
    final newCount = aDraft.lines.where((aLine) => aLine.itemId == null).length;
    final summary = 'receipt.recognized'.tr(args: ['${aDraft.lines.length}', '$newCount']);
    final mismatch = aDraft.isTotalMismatch
        ? 'receipt.total_mismatch'.tr(args: [
            formatMoney(context, aDraft.payable, currCode),
            formatMoney(context, aDraft.total!, currCode),
          ])
        : null;
    final blank = _rows.where((aRow) => aRow.isBlank).toList();

    setState(()
    {
      if (aDraft.receiptTs != null)
      {
        _ts = aDraft.receiptTs!;
      }
      if (aDraft.currId != null)
      {
        _currId = aDraft.currId;
        _isCashChosen = false;
      }
      if (aDraft.storeName != null && _merchantCtrl.text.trim().isEmpty)
      {
        _merchantCtrl.text = aDraft.storeName!;
        _merchantId = null;
      }
      if (aDraft.placeId != null)
      {
        _placeId = aDraft.placeId;
        _placeAddrId = aDraft.placeAddrId;
      }
      else if (aDraft.newPlace != null)
      {
        _placeId = null;
        _placeAddrId = null;
      }
      _newPlace = aDraft.newPlace;

      for (final row in blank)
      {
        _rows.remove(row);
        row.dispose();
      }
      _rows.addAll(aDraft.lines.map(_ItemRow.recognized));
      if (_rows.isEmpty)
      {
        _rows.add(_ItemRow());
      }
      _discountCtrl.text = _discountText(aDraft.discount);
      _recognitionNote = mismatch == null ? summary : '$summary $mismatch';
    });
  }

  Future<DictItemDto?> _itemByBarcode(String aCode) async
  {
    final found = await ref.read(apiProv).getItems(aBarcode: aCode, aLimit: 1);
    if (found.isNotEmpty || !mounted)
    {
      return found.firstOrNull;
    }
    return showItemCreateDialog(context, aCode);
  }

  Future<String?> _addScanned(String aCode) async
  {
    try
    {
      final item = await _itemByBarcode(aCode);
      if (item == null || !mounted)
      {
        return 'scanner.skipped'.tr();
      }

      _ItemRow? added;
      setState(()
      {
        final filled = _rows.where((aRow) => !aRow.isBlank).toList();
        final last = filled.lastOrNull;
        if (last != null && last.itemId == item.id)
        {
          last.qtyCtrl.text = _ItemRow._trimZeros(last.qty + 1);
          last.recalc();
          return;
        }

        final target = _rows.where((aRow) => aRow.isBlank).firstOrNull ?? _ItemRow();
        if (!_rows.contains(target))
        {
          _rows.add(target);
        }
        target.select(item);
        target.qtyCtrl.text = '1';
        added = target;
      });
      final row = added;
      if (row != null)
      {
        await _prefillPrice(row);
      }
      return 'scanner.added'.tr(args: [item.name]);
    }
    catch (aError)
    {
      return errorText(aError);
    }
  }

  Future<void> _scanIntoRow(_ItemRow aRow) async
  {
    final code = await scanBarcode(context);
    if (code == null || !mounted)
    {
      return;
    }

    try
    {
      final item = await _itemByBarcode(code);
      if (item != null && mounted)
      {
        setState(() => aRow.select(item));
        await _prefillPrice(aRow);
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

  Future<void> _chooseRecognitionSource() async
  {
    final source = await choosePhotoSource(context, 'receipt.take_photo'.tr());
    if (source != null)
    {
      await _recognize(source);
    }
  }

  List<PlaceDto> _placeOptions()
  {
    final saved = _saved;
    final isMissing = saved?.placeId != null && !_places.any((aPlace) => aPlace.id == saved!.placeId);
    if (!isMissing)
    {
      return _places;
    }

    final branch = saved!.placeAddrId == null
        ? const <PlaceAddrDto>[]
        : [
            PlaceAddrDto(
              id: saved.placeAddrId,
              isMain: true,
              countryId: '',
              cityId: '',
              label: saved.branch,
            ),
          ];
    return [
      ..._places,
      PlaceDto(id: saved.placeId!, name: saved.placeName ?? '', isEditable: false, addrs: branch),
    ];
  }

  List<PlaceAddrDto> _branchesOf(String? aPlaceId)
  {
    for (final place in _placeOptions())
    {
      if (place.id == aPlaceId)
      {
        return place.addrs;
      }
    }
    return const [];
  }

  Future<List<_ItemChoice>> _itemChoices(String aText) async
  {
    final query = aText.trim();
    if (query.isEmpty)
    {
      return const [];
    }

    List<DictItemDto> items;
    try
    {
      items = await ref.read(apiProv).getItems(aQuery: query, aLimit: 20);
    }
    catch (_)
    {
      items = const [];
    }

    final isKnown = items.any((aItem) => aItem.name.toLowerCase() == query.toLowerCase() || aItem.barcode == query);
    return [
      ...items.map(_ItemChoice.existing),
      if (!isKnown) _ItemChoice.create(query),
    ];
  }

  Future<void> _choose(_ItemRow aRow, _ItemChoice aChoice) async
  {
    final item = aChoice.item ?? await showItemCreateDialog(context, aChoice.newName);
    if (item != null && mounted)
    {
      setState(() => aRow.select(item));
      await _prefillPrice(aRow);
    }
  }

  bool _isPriceTaken(_ItemRow aRow) => aRow.priceFocus.hasFocus || aRow.priceCtrl.text.trim().isNotEmpty;

  Future<void> _prefillPrice(_ItemRow aRow) async
  {
    final itemId = aRow.itemId;
    if (itemId == null || _isPriceTaken(aRow) || _currId == null)
    {
      return;
    }

    try
    {
      final last = await ref.read(apiProv).getLastPrice(itemId, aPlaceId: _placeId, aCurrId: _currId);
      if (last == null || !mounted || aRow.itemId != itemId || _isPriceTaken(aRow))
      {
        return;
      }
      setState(()
      {
        aRow.priceCtrl.text = last.unitPrice.toStringAsFixed(2);
        aRow.isPricePrefilled = true;
        aRow.recalc();
      });
    }
    catch (_)
    {
      return;
    }
  }

  Widget _buildItemPicker(_ItemRow aRow, InputDecoration aDecoration)
  {
    final hasText = aRow.nameCtrl.text.trim().isNotEmpty;
    final Widget? state = switch (aRow)
    {
      _ItemRow(isPicked: true, match: LineMatch.similar) => Tooltip(
          message: 'receipt.similar_hint'.tr(args: [aRow.sourceText ?? '']),
          child: Icon(AppIcons.alertCircle, size: 18, color: context.palette.warning),
        ),
      _ItemRow(isPicked: true) => Icon(itemKindIcon(aRow.kind), size: 18, color: context.colors.primary),
      _ItemRow(isNew: true) => Tooltip(
          message: 'receipt.new_item_hint'.tr(),
          child: Icon(AppIcons.plusCircle, size: 18, color: context.palette.positive),
        ),
      _ when hasText => Tooltip(
          message: 'items.pick_hint'.tr(),
          child: Icon(AppIcons.alertCircle, size: 18, color: context.palette.warning),
        ),
      _ => null,
    };
    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state != null) state,
        IconButton(
          tooltip: 'scanner.title'.tr(),
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.scanBarcode, size: 18),
          onPressed: () => _scanIntoRow(aRow),
        ),
      ],
    );

    return RawAutocomplete<_ItemChoice>(
      textEditingController: aRow.nameCtrl,
      focusNode: aRow.nameFocus,
      displayStringForOption: (aChoice) => aChoice.label,
      optionsBuilder: (aValue) => _itemChoices(aValue.text),
      onSelected: (aChoice) => _choose(aRow, aChoice),
      fieldViewBuilder: (aContext, aCtrl, aFocus, aOnSubmitted) => TextField(
        controller: aCtrl,
        focusNode: aFocus,
        inputFormatters: [LengthLimitingTextInputFormatter(maxItemNameLen)],
        onChanged: (aText) => setState(() => aRow.onNameEdited(aText)),
        onSubmitted: (_) => aOnSubmitted(),
        decoration: aDecoration.copyWith(hintText: 'items.pick_hint'.tr(), suffixIcon: status),
      ),
      optionsViewBuilder: (aContext, aOnSelected, aOptions) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300, maxWidth: 420),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: aOptions.indexed
                  .map((aEntry) => _ItemChoiceTile(
                        choice: aEntry.$2,
                        isHighlighted: AutocompleteHighlightedOption.of(aContext) == aEntry.$1,
                        onTap: () => aOnSelected(aEntry.$2),
                      ))
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

    final picker = _buildItemPicker(aRow, decoration('finance.item_name'.tr()));
    final qty = TextField(
      controller: aRow.qtyCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: amountFormatters,
      onChanged: (_) => setState(aRow.recalc),
      decoration: decoration('finance.qty'.tr()).copyWith(
        hintText: '1',
        suffixText: aRow.isPicked ? itemUnitShort(aRow.unit) : null,
      ),
    );
    final price = TextField(
      controller: aRow.priceCtrl,
      focusNode: aRow.priceFocus,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: amountFormatters,
      onChanged: (_) => setState(()
      {
        aRow.isPricePrefilled = false;
        aRow.recalc();
      }),
      decoration: decoration('finance.price'.tr()).copyWith(
        suffixIcon: aRow.isPricePrefilled
            ? Tooltip(
                message: 'items.price_prefilled'.tr(),
                child: Icon(AppIcons.history, size: 16, color: context.palette.inkMuted),
              )
            : null,
      ),
    );
    final amount = TextField(
      controller: aRow.amountCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: amountFormatters,
      onChanged: (_) => setState(() {}),
      decoration: decoration('finance.amount'.tr()),
    );
    final remove = IconButton(
      tooltip: 'common.delete'.tr(),
      icon: const Icon(AppIcons.x, size: 18),
      onPressed: () => setState(()
      {
        _rows.remove(aRow);
        aRow.dispose();
      }),
    );

    return Padding(
      key: aRow.key,
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (_, aConstraints)
        {
          if (aConstraints.maxWidth >= _wideRowWidth)
          {
            return Row(
              children: [
                Expanded(flex: 5, child: picker),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: qty),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: price),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: amount),
                remove,
              ],
            );
          }

          return DecoratedBox(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: context.palette.border))),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  Row(children: [Expanded(child: picker), remove]),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 48),
                    child: Row(
                      children: [
                        Expanded(flex: 3, child: qty),
                        const SizedBox(width: 8),
                        Expanded(flex: 3, child: price),
                        const SizedBox(width: 8),
                        Expanded(flex: 4, child: amount),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVirtualRow(BuildContext aContext, String aLabel, double aAmount, IconData aIcon)
  {
    return Container(
      margin: const EdgeInsets.only(bottom: 8, right: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: context.palette.surfaceMuted,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: context.palette.border),
      ),
      child: Row(
        children: [
          Icon(aIcon, size: 16, color: context.palette.inkMuted),
          const SizedBox(width: 8),
          Expanded(child: Text(aLabel, style: TextStyle(fontStyle: FontStyle.italic, color: context.palette.inkSecondary))),
          Text(formatMoney(aContext, aAmount, _currCode), style: TextStyle(color: context.palette.inkSecondary)),
        ],
      ),
    );
  }

  Widget _buildTotals(BuildContext aContext, double aItemsTotal, double aDiscount, double aPaidTotal)
  {
    Widget line(String aLabel, double aValue, {bool aIsBold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(aLabel, style: TextStyle(color: context.palette.inkSecondary))),
              Text(
                formatMoney(aContext, aValue, _currCode),
                style: TextStyle(fontWeight: aIsBold ? FontWeight.bold : FontWeight.w500, color: context.palette.inkPrimary),
              ),
            ],
          ),
        );

    final payable = aItemsTotal - aDiscount;
    final total = payable > aPaidTotal ? payable : aPaidTotal;

    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.palette.border),
      ),
      child: Column(
        children: [
          line('finance.items_total'.tr(), aItemsTotal),
          if (aDiscount > 0.004) ...[
            line('finance.receipt_discount'.tr(), -aDiscount),
            line('finance.payable'.tr(), payable),
          ],
          line('finance.paid_by_tx'.tr(), aPaidTotal),
          if (aPaidTotal > payable + 0.004) line('finance.rest'.tr(), aPaidTotal - payable),
          if (payable > aPaidTotal + 0.004) line('finance.cash_rest'.tr(), payable - aPaidTotal),
          const Divider(),
          line('finance.receipt_total'.tr(), total, aIsBold: true),
        ],
      ),
    );
  }
}

class _ItemChoiceTile extends StatelessWidget
{
  final _ItemChoice choice;
  final bool isHighlighted;
  final VoidCallback onTap;

  const _ItemChoiceTile({required this.choice, required this.isHighlighted, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    final item = choice.item;

    return ListTile(
      dense: true,
      tileColor: isHighlighted ? aContext.colors.primaryContainer : null,
      leading: Icon(item == null ? AppIcons.plusCircle : itemKindIcon(item.kind), size: 18),
      title: Text(item?.name ?? 'items.create_option'.tr(args: [choice.newName])),
      subtitle: item == null
          ? null
          : Text([
              itemKindLabel(item.kind),
              itemUnitShort(item.unit),
              if (item.barcode != null) item.barcode!,
              itemOwnerLabel(item),
            ].join(' · ')),
      onTap: onTap,
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
        height: dialogListHeight(aContext, 420),
        child: _error != null
            ? Center(child: Text(errorText(_error!)))
            : items == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(child: Text('finance.no_candidates'.tr(), style: TextStyle(color: context.palette.inkMuted)))
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
