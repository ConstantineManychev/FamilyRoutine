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
import '../finance/finance_dialogs.dart';

const Color _borderColor = Color(0xFFE5E7EB);
const double _dialogWidth = 420;

final List<TextInputFormatter> _signedAmountFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\s-]')),
  LengthLimitingTextInputFormatter(16),
];

String _amountText(double aValue) => aValue.toStringAsFixed(2);

class BalanceDocsCard extends ConsumerStatefulWidget
{
  final AccountDto wallet;

  const BalanceDocsCard({super.key, required this.wallet});

  @override
  ConsumerState<BalanceDocsCard> createState() => _BalanceDocsCardState();
}

class _BalanceDocsCardState extends ConsumerState<BalanceDocsCard>
{
  late AccountDto _wallet = widget.wallet;
  List<BalanceDoc>? _docs;
  Object? _error;
  bool _isBusy = false;

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
      final api = ref.read(apiProv);
      final docs = await api.getBalanceDocs(_wallet.id);
      final wallet = await api.getWallet(_wallet.id);
      if (mounted)
      {
        setState(()
        {
          _docs = docs;
          _wallet = wallet;
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

  Future<void> _afterChange(bool? aIsChanged) async
  {
    if (aIsChanged ?? false)
    {
      ref.invalidate(walletsProv);
      await _load();
    }
  }

  Future<void> _editDoc(BalanceDoc? aDoc) async
  {
    final isSaved = await showDialog<bool>(
      context: context,
      builder: (_) => _BalanceDocDialog(wallet: _wallet, doc: aDoc),
    );
    await _afterChange(isSaved);
  }

  Future<void> _deleteDoc(BalanceDoc aDoc) async
  {
    final isConfirmed = await showDialog<bool>(
      context: context,
      builder: (aContext) => AlertDialog(
        title: Text('balance.delete_title'.tr()),
        content: Text(
          aDoc.writeOffs.isEmpty
              ? 'balance.delete_confirm'.tr()
              : 'balance.delete_confirm_write_offs'.tr(args: ['${aDoc.writeOffs.length}']),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(aContext).pop(false), child: Text('common.cancel'.tr())),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(aContext).pop(true),
            child: Text('common.delete'.tr()),
          ),
        ],
      ),
    );
    if (!(isConfirmed ?? false))
    {
      return;
    }

    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).deleteBalanceDoc(aDoc.id);
      await _afterChange(true);
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
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _writeOff(BalanceDoc aDoc) async
  {
    final isSaved = await showDialog<bool>(
      context: context,
      builder: (_) => _WriteOffDialog(wallet: _wallet, doc: aDoc),
    );
    await _afterChange(isSaved);
  }

  Future<void> _addReceipt(BalanceDoc aDoc) async
  {
    final isSaved = await context.push<bool>(
      '/app/receipts/new',
      extra: ReceiptPrefill(cashAccountId: _wallet.id, currId: _wallet.currId, ts: aDoc.balanceTs),
    );
    await _afterChange(isSaved);
  }

  @override
  Widget build(BuildContext aContext)
  {
    final docs = _docs;
    final balance = _wallet.balance ?? 0;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _borderColor)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('balance.title'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      formatMoney(aContext, balance, _wallet.currCode),
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: inkPrimary),
                    ),
                  ],
                ),
                if (_wallet.isEditable)
                  FilledButton.icon(
                    onPressed: _isBusy ? null : () => _editDoc(null),
                    icon: const Icon(AppIcons.plus, size: 18),
                    label: Text('balance.set'.tr()),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('balance.hint'.tr(), style: const TextStyle(color: inkSecondary)),
            const SizedBox(height: 12),
            if (_error != null)
              ErrorRetry(error: _error!, onRetry: _load)
            else if (docs == null)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
            else if (docs.isEmpty)
              Text('balance.empty'.tr(), style: const TextStyle(color: inkMuted))
            else
              for (final doc in docs) _buildDoc(aContext, doc),
          ],
        ),
      ),
    );
  }

  Widget _buildDoc(BuildContext aContext, BalanceDoc aDoc)
  {
    final currCode = _wallet.currCode;
    final delta = aDoc.delta ?? 0;
    final Widget status;
    if (aDoc.isInitial)
    {
      status = Text('balance.initial'.tr(), style: const TextStyle(color: inkSecondary));
    }
    else if (!aDoc.hasDelta)
    {
      status = Row(
        children: [
          Icon(AppIcons.checkCircle, size: 16, color: Colors.green.shade700),
          const SizedBox(width: 6),
          Expanded(child: Text('balance.matches'.tr(), style: TextStyle(color: Colors.green.shade800))),
        ],
      );
    }
    else
    {
      status = Row(
        children: [
          Icon(AppIcons.alertCircle, size: 16, color: Colors.orange.shade800),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'balance.delta'.tr(args: [
                formatMoney(aContext, delta, currCode, aIsSigned: true),
                formatMoney(aContext, aDoc.expected ?? 0, currCode),
              ]),
              style: TextStyle(color: Colors.orange.shade900),
            ),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _borderColor)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatMoney(aContext, aDoc.amount, currCode),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: inkPrimary),
                    ),
                    Text(
                      [formatDateTime(aContext, aDoc.balanceTs), if (aDoc.note != null) aDoc.note!].join(' · '),
                      style: const TextStyle(color: inkSecondary),
                    ),
                  ],
                ),
              ),
              if (_wallet.isEditable)
                PopupMenuButton<String>(
                  tooltip: 'common.actions'.tr(),
                  enabled: !_isBusy,
                  onSelected: (aValue) => aValue == 'edit' ? _editDoc(aDoc) : _deleteDoc(aDoc),
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'edit', child: Text('balance.edit'.tr())),
                    PopupMenuItem(value: 'delete', child: Text('common.delete'.tr(), style: const TextStyle(color: Colors.red))),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          status,
          for (final writeOff in aDoc.writeOffs)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 22),
              child: Text(
                [
                  'balance.written_off'.tr(args: [formatMoney(aContext, writeOff.amount, currCode, aIsSigned: true)]),
                  categoryLabel(writeOff.category),
                  formatDateTime(aContext, writeOff.txTs),
                  if (writeOff.note != null) writeOff.note!,
                ].join(' · '),
                style: const TextStyle(color: inkSecondary, fontSize: 13),
              ),
            ),
          if (_wallet.isEditable && aDoc.hasDelta)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: _isBusy ? null : () => _writeOff(aDoc),
                    icon: const Icon(AppIcons.pencil, size: 16),
                    label: Text(delta < 0 ? 'balance.write_off_expense'.tr() : 'balance.write_off_income'.tr()),
                  ),
                  if (_wallet.isCash && delta < 0)
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : () => _addReceipt(aDoc),
                      icon: const Icon(AppIcons.receipt, size: 16),
                      label: Text('balance.add_receipt'.tr()),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BalanceDocDialog extends ConsumerStatefulWidget
{
  final AccountDto wallet;
  final BalanceDoc? doc;

  const _BalanceDocDialog({required this.wallet, this.doc});

  @override
  ConsumerState<_BalanceDocDialog> createState() => _BalanceDocDialogState();
}

class _BalanceDocDialogState extends ConsumerState<_BalanceDocDialog>
{
  late final _amountCtrl = TextEditingController(text: widget.doc == null ? '' : _amountText(widget.doc!.amount));
  late final _noteCtrl = TextEditingController(text: widget.doc?.note ?? '');
  late DateTime _ts = widget.doc?.balanceTs ?? DateTime.now();
  bool _isSaving = false;

  @override
  void dispose()
  {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async
  {
    final amount = parseAmountInput(_amountCtrl.text);
    if (amount == null)
    {
      showInfoSnack(context, 'balance.err_amount'.tr());
      return;
    }

    setState(() => _isSaving = true);
    try
    {
      final api = ref.read(apiProv);
      final note = _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim();
      final doc = widget.doc;
      if (doc == null)
      {
        await api.createBalanceDoc(widget.wallet.id, _ts, amount, note);
      }
      else
      {
        await api.updateBalanceDoc(doc.id, _ts, amount, note);
      }
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
    return AlertDialog(
      title: Text(widget.doc == null ? 'balance.set'.tr() : 'balance.edit'.tr()),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'balance.current_hint'.tr(args: [formatMoney(aContext, widget.wallet.balance ?? 0, widget.wallet.currCode)]),
                style: const TextStyle(color: inkSecondary),
              ),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                child: TextField(
                  controller: _amountCtrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  inputFormatters: _signedAmountFormatters,
                  decoration: InputDecoration(
                    labelText: 'balance.amount'.tr(),
                    suffixText: widget.wallet.currCode,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DateTimeField(value: _ts, onChanged: (aValue) => setState(() => _ts = aValue)),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                child: TextField(
                  controller: _noteCtrl,
                  inputFormatters: [LengthLimitingTextInputFormatter(500)],
                  decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _isSaving ? null : () => Navigator.of(context).pop(false), child: Text('common.cancel'.tr())),
        FilledButton(onPressed: _isSaving ? null : _save, child: Text('common.save'.tr())),
      ],
    );
  }
}

class _WriteOffDialog extends ConsumerStatefulWidget
{
  final AccountDto wallet;
  final BalanceDoc doc;

  const _WriteOffDialog({required this.wallet, required this.doc});

  @override
  ConsumerState<_WriteOffDialog> createState() => _WriteOffDialogState();
}

class _WriteOffDialogState extends ConsumerState<_WriteOffDialog>
{
  late final bool _isExpense = (widget.doc.delta ?? 0) < 0;
  late final double _limit = (widget.doc.delta ?? 0).abs();
  late final _amountCtrl = TextEditingController(text: _amountText(_limit));
  final _noteCtrl = TextEditingController();
  late DateTime _ts = widget.doc.balanceTs;
  late TxCategory? _category = _isExpense ? TxCategory.other : TxCategory.income;
  bool _isSaving = false;

  @override
  void dispose()
  {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async
  {
    final amount = parseAmountInput(_amountCtrl.text);
    if (amount == null || amount <= 0 || amount > _limit + 0.004)
    {
      showInfoSnack(context, 'balance.err_write_off'.tr(args: [formatMoney(context, _limit, widget.wallet.currCode)]));
      return;
    }

    final prevTs = widget.doc.prevTs;
    if (_ts.isAfter(widget.doc.balanceTs) || (prevTs != null && !_ts.isAfter(prevTs)))
    {
      showInfoSnack(context, 'balance.err_write_off_date'.tr());
      return;
    }

    setState(() => _isSaving = true);
    try
    {
      final note = _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim();
      await ref.read(apiProv).writeOffBalance(widget.doc.id, _isExpense ? -amount : amount, _ts, _category, note);
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
    final prevTs = widget.doc.prevTs;

    return AlertDialog(
      title: Text(_isExpense ? 'balance.write_off_expense'.tr() : 'balance.write_off_income'.tr()),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'balance.write_off_hint'.tr(args: [
                  formatMoney(aContext, _limit, widget.wallet.currCode),
                  if (prevTs != null) formatDateTime(aContext, prevTs) else '—',
                  formatDateTime(aContext, widget.doc.balanceTs),
                ]),
                style: const TextStyle(color: inkSecondary),
              ),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: amountFormatters,
                  decoration: InputDecoration(
                    labelText: 'finance.amount'.tr(),
                    suffixText: widget.wallet.currCode,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<TxCategory?>(
                initialValue: _category,
                isExpanded: true,
                decoration: InputDecoration(labelText: 'finance.category'.tr(), border: const OutlineInputBorder()),
                items: [
                  for (final category in TxCategory.values.where((aCategory) => aCategory != TxCategory.transfer))
                    DropdownMenuItem<TxCategory?>(value: category, child: Text(categoryLabel(category))),
                ],
                onChanged: (aValue) => setState(() => _category = aValue),
              ),
              const SizedBox(height: 16),
              DateTimeField(value: _ts, onChanged: (aValue) => setState(() => _ts = aValue)),
              const SizedBox(height: 16),
              Semantics(
                container: true,
                child: TextField(
                  controller: _noteCtrl,
                  inputFormatters: [LengthLimitingTextInputFormatter(500)],
                  decoration: InputDecoration(labelText: 'finance.note'.tr(), border: const OutlineInputBorder()),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _isSaving ? null : () => Navigator.of(context).pop(false), child: Text('common.cancel'.tr())),
        FilledButton(onPressed: _isSaving ? null : _save, child: Text('common.save'.tr())),
      ],
    );
  }
}
