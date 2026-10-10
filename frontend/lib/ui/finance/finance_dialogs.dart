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
import 'transactions_screen.dart';

final List<TextInputFormatter> amountFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s]')),
  LengthLimitingTextInputFormatter(16),
];

Future<DateTime?> pickDateTime(BuildContext aContext, DateTime aInitial) async
{
  final date = await showDatePicker(
    context: aContext,
    initialDate: aInitial,
    firstDate: DateTime(2000),
    lastDate: DateTime.now().add(const Duration(days: 1)),
  );

  if (date == null || !aContext.mounted)
  {
    return null;
  }

  final time = await showTimePicker(context: aContext, initialTime: TimeOfDay.fromDateTime(aInitial));
  final picked = time ?? TimeOfDay.fromDateTime(aInitial);
  return DateTime(date.year, date.month, date.day, picked.hour, picked.minute);
}

class DateTimeField extends StatelessWidget
{
  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  const DateTimeField({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext aContext)
  {
    return InkWell(
      onTap: () async
      {
        final picked = await pickDateTime(aContext, value);
        if (picked != null)
        {
          onChanged(picked);
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'finance.date'.tr(),
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(AppIcons.calendar),
        ),
        child: Text(formatDateTime(aContext, value)),
      ),
    );
  }
}

class CashEntryDialog extends ConsumerStatefulWidget
{
  final bool isIncome;

  const CashEntryDialog({super.key, required this.isIncome});

  @override
  ConsumerState<CashEntryDialog> createState() => _CashEntryDialogState();
}

class _CashEntryDialogState extends ConsumerState<CashEntryDialog>
{
  final _amountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  late bool _isIncome = widget.isIncome;
  String? _accountId;
  DateTime _ts = DateTime.now();
  bool _isSaving = false;

  @override
  void dispose()
  {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(List<AccountDto> aWallets) async
  {
    final amount = parseAmountInput(_amountCtrl.text);
    final accountId = _accountId ?? (aWallets.isEmpty ? null : aWallets.first.id);

    if (amount == null || amount <= 0 || accountId == null)
    {
      showInfoSnack(context, 'finance.err_amount'.tr());
      return;
    }

    setState(() => _isSaving = true);

    try
    {
      final note = _noteCtrl.text.trim();
      await ref.read(apiProv).createTransaction(accountId, _isIncome ? amount : -amount, _ts, note.isEmpty ? null : note);
      if (mounted)
      {
        Navigator.of(context).pop(true);
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

  @override
  Widget build(BuildContext aContext)
  {
    final wallets = (ref.watch(walletsProv).valueOrNull ?? const <AccountDto>[])
        .where((aWallet) => aWallet.isActive && aWallet.isEditable && !aWallet.isLinked)
        .toList()
      ..sort((aLeft, aRight) => (aRight.isCash ? 1 : 0) - (aLeft.isCash ? 1 : 0));

    return AlertDialog(
      title: Text('finance.cash_entry'.tr()),
      content: SizedBox(
        width: 420,
        child: wallets.isEmpty
            ? Text('finance.no_manual_wallets'.tr())
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(value: true, label: Text('finance.income'.tr()), icon: const Icon(AppIcons.arrowDownLeft)),
                      ButtonSegment(value: false, label: Text('finance.expense'.tr()), icon: const Icon(AppIcons.arrowUpRight)),
                    ],
                    selected: {_isIncome},
                    onSelectionChanged: (aValue) => setState(() => _isIncome = aValue.first),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _accountId ?? wallets.first.id,
                    decoration: InputDecoration(labelText: 'finance.wallet'.tr(), border: const OutlineInputBorder()),
                    items: wallets
                        .map((aWallet) => DropdownMenuItem(value: aWallet.id, child: Text('${aWallet.name} · ${aWallet.currCode}')))
                        .toList(),
                    onChanged: (aValue) => setState(() => _accountId = aValue),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _amountCtrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: amountFormatters,
                    decoration: InputDecoration(labelText: 'finance.amount'.tr(), border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  DateTimeField(value: _ts, onChanged: (aValue) => setState(() => _ts = aValue)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _noteCtrl,
                    inputFormatters: [LengthLimitingTextInputFormatter(500)],
                    decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: _isSaving || wallets.isEmpty ? null : () => _save(wallets),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

class TransferDialog extends ConsumerStatefulWidget
{
  final TxDto? fromTx;

  const TransferDialog({super.key, this.fromTx});

  @override
  ConsumerState<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<TransferDialog>
{
  final _amountCtrl = TextEditingController();
  final _toAmountCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String? _fromId;
  String? _toId;
  TxDto? _fromTx;
  List<TxDto> _candidates = const [];
  DateTime _ts = DateTime.now();
  bool _isSaving = false;

  @override
  void initState()
  {
    super.initState();
    _fromTx = widget.fromTx;
    _fromId = widget.fromTx?.accountId;
    if (widget.fromTx != null)
    {
      _ts = widget.fromTx!.txTs;
      _amountCtrl.text = (-widget.fromTx!.amount).toStringAsFixed(2);
    }
  }

  @override
  void dispose()
  {
    _amountCtrl.dispose();
    _toAmountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates(String aAccountId) async
  {
    try
    {
      final page = await ref.read(apiProv).getTransactions(aAccountId: aAccountId, aLimit: 60);
      if (mounted)
      {
        setState(() => _candidates = page.items
            .where((aTx) => aTx.isOutflow && !aTx.isTransfer && aTx.receiptId == null && !aTx.isReceiptCash)
            .toList());
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

  Future<void> _save(AccountDto aFrom, AccountDto aTo) async
  {
    final amount = parseAmountInput(_amountCtrl.text);
    final toAmount = parseAmountInput(_toAmountCtrl.text);
    final isSameCurrency = aFrom.currId == aTo.currId;

    if (aFrom.isLinked && _fromTx == null)
    {
      showInfoSnack(context, 'finance.err_pick_tx'.tr());
      return;
    }

    if (!aFrom.isLinked && (amount == null || amount <= 0))
    {
      showInfoSnack(context, 'finance.err_amount'.tr());
      return;
    }

    if (!isSameCurrency && (toAmount == null || toAmount <= 0))
    {
      showInfoSnack(context, 'finance.err_to_amount'.tr());
      return;
    }

    setState(() => _isSaving = true);

    try
    {
      final note = _noteCtrl.text.trim();
      await ref.read(apiProv).createTransfer(
            aFromAccountId: aFrom.id,
            aToAccountId: aTo.id,
            aTs: _fromTx?.txTs ?? _ts,
            aAmount: aFrom.isLinked ? null : amount,
            aToAmount: isSameCurrency ? null : toAmount,
            aFromTxId: _fromTx?.id,
            aNote: note.isEmpty ? null : note,
          );
      if (mounted)
      {
        Navigator.of(context).pop(true);
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

  @override
  Widget build(BuildContext aContext)
  {
    final wallets = (ref.watch(walletsProv).valueOrNull ?? const <AccountDto>[])
        .where((aWallet) => aWallet.isActive && aWallet.isEditable)
        .toList();
    final cashWallets = wallets.where((aWallet) => aWallet.isCash && !aWallet.isLinked).toList();
    final from = wallets.where((aWallet) => aWallet.id == _fromId).firstOrNull;
    final targets = wallets.where((aWallet) => aWallet.id != _fromId && !aWallet.isLinked).toList();
    final to = targets.where((aWallet) => aWallet.id == _toId).firstOrNull ??
        cashWallets.where((aWallet) => aWallet.id != _fromId).firstOrNull ??
        targets.firstOrNull;

    return AlertDialog(
      title: Text('finance.to_cash'.tr()),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('finance.to_cash_hint'.tr(), style: const TextStyle(color: inkSecondary)),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _fromId,
                decoration: InputDecoration(labelText: 'finance.from_wallet'.tr(), border: const OutlineInputBorder()),
                items: wallets
                    .map((aWallet) => DropdownMenuItem(value: aWallet.id, child: Text('${aWallet.name} · ${aWallet.currCode}')))
                    .toList(),
                onChanged: widget.fromTx != null
                    ? null
                    : (aValue)
                    {
                      setState(()
                      {
                        _fromId = aValue;
                        _fromTx = null;
                        _candidates = const [];
                      });
                      final selected = wallets.where((aWallet) => aWallet.id == aValue).firstOrNull;
                      if (selected != null && selected.isLinked)
                      {
                        _loadCandidates(selected.id);
                      }
                    },
              ),
              const SizedBox(height: 16),
              if (from != null && from.isLinked) ...[
                if (_fromTx != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(AppIcons.link),
                    title: Text(_fromTx!.title),
                    subtitle: Text(formatDateTime(aContext, _fromTx!.txTs)),
                    trailing: Text(formatMoney(aContext, _fromTx!.amount, _fromTx!.currCode)),
                  )
                else
                  DropdownButtonFormField<String>(
                    decoration: InputDecoration(labelText: 'finance.pick_withdrawal'.tr(), border: const OutlineInputBorder()),
                    isExpanded: true,
                    items: _candidates
                        .map((aTx) => DropdownMenuItem(
                              value: aTx.id,
                              child: Text(
                                '${DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aTx.txTs)} · ${aTx.title} · ${formatMoney(aContext, aTx.amount, aTx.currCode)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (aValue) => setState(() => _fromTx = _candidates.where((aTx) => aTx.id == aValue).firstOrNull),
                  ),
                const SizedBox(height: 16),
              ],
              DropdownButtonFormField<String>(
                key: ValueKey('to-$_fromId'),
                initialValue: to?.id,
                decoration: InputDecoration(labelText: 'finance.to_wallet'.tr(), border: const OutlineInputBorder()),
                items: targets
                    .map((aWallet) => DropdownMenuItem(value: aWallet.id, child: Text('${aWallet.name} · ${aWallet.currCode}')))
                    .toList(),
                onChanged: (aValue) => setState(() => _toId = aValue),
              ),
              if (from != null && !from.isLinked) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: amountFormatters,
                  decoration: InputDecoration(
                    labelText: '${'finance.amount'.tr()} (${from.currCode})',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                DateTimeField(value: _ts, onChanged: (aValue) => setState(() => _ts = aValue)),
              ],
              if (from != null && to != null && from.currId != to.currId) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _toAmountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: amountFormatters,
                  decoration: InputDecoration(
                    labelText: '${'finance.received_amount'.tr()} (${to.currCode})',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _noteCtrl,
                inputFormatters: [LengthLimitingTextInputFormatter(500)],
                decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: _isSaving || from == null || to == null ? null : () => _save(from, to),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

class TxDetailDialog extends ConsumerStatefulWidget
{
  final TxDto tx;

  const TxDetailDialog({super.key, required this.tx});

  @override
  ConsumerState<TxDetailDialog> createState() => _TxDetailDialogState();
}

class _TxDetailDialogState extends ConsumerState<TxDetailDialog>
{
  late final _noteCtrl = TextEditingController(text: widget.tx.note ?? '');
  late TxCategory? _category = widget.tx.category;
  bool _isApplyToSimilar = false;
  bool _isBusy = false;

  @override
  void dispose()
  {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);

    try
    {
      await aAction();
      if (mounted)
      {
        Navigator.of(context).pop(true);
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

  void _leaveTo(BuildContext aContext, String aPath, {Object? aExtra})
  {
    final router = GoRouter.of(aContext);
    Navigator.of(aContext).pop(false);
    router.go(aPath, extra: aExtra);
  }

  Future<void> _toCash() async
  {
    final isDone = await showDialog<bool>(context: context, builder: (_) => TransferDialog(fromTx: widget.tx));
    if (isDone == true && mounted)
    {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _linkTransfer() async
  {
    final isDone = await showDialog<bool>(context: context, builder: (_) => LinkTransferDialog(tx: widget.tx));
    if (isDone == true && mounted)
    {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final tx = widget.tx;
    final api = ref.read(apiProv);
    final canLinkCash = tx.isEditable && tx.isOutflow && !tx.isTransfer && tx.receiptId == null && !tx.isReceiptCash;
    final canLinkTransfer = tx.isEditable && !tx.isTransfer && tx.receiptId == null && !tx.isReceiptCash;
    final canApplyToSimilar = tx.similarKey != null && _category != null && _category != tx.category;
    final details = [
      if (tx.description != null && tx.description != tx.title) tx.description!,
      if (tx.counterparty != null && tx.counterparty != tx.title) tx.counterparty!,
      if (tx.opAmount != null && tx.opCurrCode != null) formatMoney(aContext, tx.opAmount!, tx.opCurrCode!),
      if (tx.mcc != null) 'MCC ${tx.mcc}',
    ];

    return AlertDialog(
      title: Text(tx.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formatMoney(aContext, tx.amount, tx.currCode, aIsSigned: true),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: tx.isTransfer ? inkSecondary : (tx.amount > 0 ? incomeColor : inkPrimary),
                ),
              ),
              const SizedBox(height: 4),
              Text('${tx.accountName} · ${formatDateTime(aContext, tx.txTs)}', style: const TextStyle(color: inkSecondary)),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(details.join(' · '), style: const TextStyle(color: inkMuted)),
              ],
              if (tx.isTransfer) ...[
                const SizedBox(height: 12),
                _TransferInfo(tx: tx),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<TxCategory?>(
                initialValue: _category,
                decoration: InputDecoration(labelText: 'finance.category'.tr(), border: const OutlineInputBorder()),
                items: [
                  DropdownMenuItem<TxCategory?>(value: null, child: Text(categoryLabel(null))),
                  ...TxCategory.values.map((aCategory) => DropdownMenuItem<TxCategory?>(
                        value: aCategory,
                        child: Row(children: [
                          Icon(categoryIcon(aCategory), size: 16),
                          const SizedBox(width: 8),
                          Text(categoryLabel(aCategory)),
                        ]),
                      )),
                ],
                onChanged: tx.isEditable ? (aValue) => setState(() => _category = aValue) : null,
              ),
              if (canApplyToSimilar)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _isApplyToSimilar,
                  onChanged: (aValue) => setState(() => _isApplyToSimilar = aValue ?? false),
                  title: Text('finance.apply_similar'.tr(args: [tx.similarKey!])),
                  subtitle: Text('finance.apply_similar_hint'.tr()),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _noteCtrl,
                enabled: tx.isEditable,
                inputFormatters: [LengthLimitingTextInputFormatter(500)],
                decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (canLinkCash)
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : _toCash,
                      icon: const Icon(AppIcons.banknote, size: 18),
                      label: Text('finance.to_cash'.tr()),
                    ),
                  if (canLinkTransfer)
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : _linkTransfer,
                      icon: const Icon(AppIcons.arrowLeftRight, size: 18),
                      label: Text('finance.link_transfer'.tr()),
                    ),
                  if (tx.receiptId != null)
                    OutlinedButton.icon(
                      onPressed: () => _leaveTo(aContext, '/app/receipts/${tx.receiptId}'),
                      icon: const Icon(AppIcons.receipt, size: 18),
                      label: Text('finance.open_receipt'.tr()),
                    )
                  else if (canLinkCash)
                    OutlinedButton.icon(
                      onPressed: () => _leaveTo(aContext, '/app/receipts/new', aExtra: tx),
                      icon: const Icon(AppIcons.receipt, size: 18),
                      label: Text('finance.make_receipt'.tr()),
                    ),
                  if (tx.isTransfer && tx.isEditable)
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : () => _run(() => api.deleteTransfer(tx.transferId!)),
                      icon: const Icon(AppIcons.unlink, size: 18),
                      label: Text('finance.unlink_transfer'.tr()),
                    ),
                  if (tx.isManual && !tx.isTransfer && tx.isEditable)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                      onPressed: _isBusy ? null : () => _run(() => api.deleteTransaction(tx.id)),
                      icon: const Icon(AppIcons.trash2, size: 18),
                      label: Text('common.delete'.tr()),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
        if (tx.isEditable)
          ElevatedButton(
            onPressed: _isBusy
                ? null
                : () => _run(() async
                    {
                      final note = _noteCtrl.text.trim();
                      await api.updateTransaction(
                        tx.id,
                        note.isEmpty ? null : note,
                        _category,
                        aIsApplyToSimilar: canApplyToSimilar && _isApplyToSimilar,
                      );
                    }),
            child: Text('common.save'.tr()),
          ),
      ],
    );
  }
}

class _TransferInfo extends StatelessWidget
{
  final TxDto tx;

  const _TransferInfo({required this.tx});

  @override
  Widget build(BuildContext aContext)
  {
    final peerName = tx.peerAccountName;
    final peerAmount = tx.peerAmount;
    final peer = peerName == null
        ? 'finance.transfer_hidden_peer'.tr()
        : peerAmount == null || tx.peerCurrCode == null
            ? peerName
            : '$peerName · ${formatMoney(aContext, peerAmount, tx.peerCurrCode!, aIsSigned: true)}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(AppIcons.arrowLeftRight, size: 16, color: inkSecondary),
              const SizedBox(width: 8),
              Expanded(child: Text('finance.transfer_between'.tr(), style: const TextStyle(fontWeight: FontWeight.w600))),
              if (tx.isAutoTransfer)
                Text('finance.transfer_auto'.tr(), style: const TextStyle(fontSize: 12, color: inkMuted)),
            ],
          ),
          const SizedBox(height: 4),
          Text(peer, style: const TextStyle(color: inkSecondary)),
          const SizedBox(height: 4),
          Text('finance.transfer_excluded'.tr(), style: const TextStyle(fontSize: 12, color: inkMuted)),
        ],
      ),
    );
  }
}

class LinkTransferDialog extends ConsumerStatefulWidget
{
  final TxDto tx;

  const LinkTransferDialog({super.key, required this.tx});

  @override
  ConsumerState<LinkTransferDialog> createState() => _LinkTransferDialogState();
}

class _LinkTransferDialogState extends ConsumerState<LinkTransferDialog>
{
  static const Duration _window = Duration(days: 7);

  List<TxDto>? _candidates;
  Object? _error;
  bool _isSaving = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  double _score(TxDto aCandidate)
  {
    final isSameAmount = aCandidate.currCode == widget.tx.currCode && aCandidate.amount == -widget.tx.amount;
    final hours = aCandidate.txTs.difference(widget.tx.txTs).inMinutes.abs() / 60;
    return (isSameAmount ? 0 : 1000) + hours;
  }

  Future<void> _load() async
  {
    try
    {
      final tx = widget.tx;
      final page = await ref.read(apiProv).getTransactions(
            aFrom: tx.txTs.subtract(_window),
            aTo: tx.txTs.add(_window),
            aLimit: 200,
          );
      final candidates = page.items
          .where((aItem) => aItem.accountId != tx.accountId)
          .where((aItem) => aItem.isOutflow != tx.isOutflow)
          .where((aItem) => !aItem.isTransfer && aItem.isEditable && aItem.receiptId == null && !aItem.isReceiptCash)
          .toList()
        ..sort((aLeft, aRight) => _score(aLeft).compareTo(_score(aRight)));
      if (mounted)
      {
        setState(() => _candidates = candidates);
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

  Future<void> _link(TxDto aPeer) async
  {
    final outflow = widget.tx.isOutflow ? widget.tx : aPeer;
    final inflow = widget.tx.isOutflow ? aPeer : widget.tx;
    setState(() => _isSaving = true);

    try
    {
      await ref.read(apiProv).createTransfer(
            aFromAccountId: outflow.accountId,
            aToAccountId: inflow.accountId,
            aTs: outflow.txTs,
            aFromTxId: outflow.id,
            aToTxId: inflow.id,
          );
      if (mounted)
      {
        Navigator.of(context).pop(true);
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

  @override
  Widget build(BuildContext aContext)
  {
    final candidates = _candidates;

    return AlertDialog(
      title: Text('finance.link_transfer'.tr()),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('finance.link_transfer_hint'.tr(), style: const TextStyle(color: inkSecondary)),
            const SizedBox(height: 12),
            Expanded(
              child: _error != null
                  ? Center(child: Text(errorText(_error!)))
                  : candidates == null
                      ? const Center(child: CircularProgressIndicator())
                      : candidates.isEmpty
                          ? Center(child: Text('finance.no_candidates'.tr(), style: const TextStyle(color: inkMuted)))
                          : ListView(
                              children: candidates
                                  .map((aItem) => TxTile(tx: aItem, onTap: _isSaving ? null : () => _link(aItem)))
                                  .toList(),
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
      ],
    );
  }
}
