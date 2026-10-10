import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'finance_dialogs.dart';

class TransactionsScreen extends ConsumerStatefulWidget
{
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen>
{
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<TxDto> _items = const [];
  String? _cursor;
  String? _accountId;
  Object? _loadError;
  bool _isLoading = false;

  @override
  void initState()
  {
    super.initState();
    _reload();
  }

  @override
  void dispose()
  {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() => _load(aIsReset: true);

  Future<void> _load({bool aIsReset = false}) async
  {
    setState(()
    {
      _isLoading = true;
      _loadError = null;
    });

    try
    {
      final page = await ref.read(apiProv).getTransactions(
            aAccountId: _accountId,
            aCursor: aIsReset ? null : _cursor,
            aQuery: _searchCtrl.text,
          );

      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _items = aIsReset ? page.items : [..._items, ...page.items];
        _cursor = page.nextCursor;
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

  void _onSearchChanged(String _)
  {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _reload);
  }

  Future<void> _openDialog(Widget aDialog) async
  {
    final isChanged = await showDialog<bool>(context: context, builder: (_) => aDialog);
    if (isChanged == true)
    {
      ref.invalidate(walletsProv);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final wallets = ref.watch(walletsProv).valueOrNull ?? const <AccountDto>[];

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'finance.transactions'.tr(),
            actions: [
              OutlinedButton.icon(
                onPressed: () => _openDialog(const TransferDialog()),
                icon: const Icon(AppIcons.arrowLeftRight, size: 18),
                label: Text('finance.to_cash'.tr()),
              ),
              ElevatedButton.icon(
                onPressed: () => _openDialog(const CashEntryDialog(isIncome: true)),
                icon: const Icon(AppIcons.banknote, size: 18),
                label: Text('finance.cash_entry'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 260,
                child: DropdownButtonFormField<String?>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'finance.wallet'.tr(),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('finance.all_wallets'.tr())),
                    ...wallets.map((aWallet) => DropdownMenuItem<String?>(value: aWallet.id, child: Text(aWallet.name))),
                  ],
                  onChanged: (aValue)
                  {
                    setState(() => _accountId = aValue);
                    _reload();
                  },
                ),
              ),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    labelText: 'finance.search'.tr(),
                    border: const OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: const Icon(AppIcons.search, size: 18),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(child: _buildList(aContext)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext aContext)
  {
    if (_loadError != null && _items.isEmpty)
    {
      return ErrorRetry(error: _loadError!, onRetry: _reload);
    }

    if (_items.isEmpty)
    {
      return _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(child: Text('finance.no_transactions'.tr(), style: const TextStyle(color: inkMuted)));
    }

    final rows = <Widget>[];
    DateTime? currentDay;

    for (final tx in _items)
    {
      final day = DateTime(tx.txTs.year, tx.txTs.month, tx.txTs.day);
      if (day != currentDay)
      {
        currentDay = day;
        rows.add(Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 6, left: 4),
          child: Text(
            formatDay(aContext, day),
            style: const TextStyle(color: inkSecondary, fontWeight: FontWeight.w600),
          ),
        ));
      }
      rows.add(TxTile(tx: tx, onTap: () => _openDialog(TxDetailDialog(tx: tx))));
    }

    if (_cursor != null)
    {
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: OutlinedButton(
            onPressed: _isLoading ? null : _load,
            child: Text('finance.load_more'.tr()),
          ),
        ),
      ));
    }

    return RefreshIndicator(onRefresh: _reload, child: ListView(children: rows));
  }
}

class TxTile extends StatelessWidget
{
  final TxDto tx;
  final VoidCallback? onTap;
  final Widget? trailing;

  const TxTile({super.key, required this.tx, this.onTap, this.trailing});

  @override
  Widget build(BuildContext aContext)
  {
    final subtitle = [
      tx.accountName,
      DateFormat.Hm(aContext.locale.toLanguageTag()).format(tx.txTs),
      if (tx.isTransfer) 'finance.transfer'.tr() else categoryLabel(tx.category),
      if (tx.isPending) 'finance.pending'.tr(),
    ].join(' · ');

    final amountColor = tx.isTransfer
        ? inkMuted
        : tx.amount > 0
            ? Colors.green.shade700
            : inkPrimary;

    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFF3F4F6),
          child: Icon(tx.isTransfer ? AppIcons.arrowLeftRight : categoryIcon(tx.category), size: 18, color: inkSecondary),
        ),
        title: Row(
          children: [
            Flexible(child: Text(tx.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (tx.receiptId != null) ...[
              const SizedBox(width: 6),
              const Icon(AppIcons.receipt, size: 14, color: inkMuted),
            ],
          ],
        ),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: trailing ??
            Text(
              formatMoney(aContext, tx.amount, tx.currCode, aIsSigned: true),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: amountColor),
            ),
      ),
    );
  }
}
