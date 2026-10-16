import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../common/page_frames.dart';
import '../common/snap_tab_view.dart';
import '../finance/cashflow_chart.dart';
import '../finance/category_view.dart';
import '../finance/finance_dialogs.dart';
import '../finance/finance_filter.dart';
import '../finance/transactions_screen.dart';
import '../wallets/bank_conns_section.dart';
import '../wallets/wallets_screen.dart';

const int _blockLimit = 5;
const double _blockGap = 16;
const double _filterBarHeight = 56;
const String _modePref = 'finance.mode';
const String _convertPref = 'finance.convert_to';
const String _isConvertPref = 'finance.is_convert';

class FinanceTab extends ConsumerStatefulWidget
{
  const FinanceTab({super.key});

  @override
  ConsumerState<FinanceTab> createState() => _FinanceTabState();
}

class _FinanceTabState extends ConsumerState<FinanceTab> with AutomaticKeepAliveClientMixin
{
  FinanceFilter _filter = const FinanceFilter();
  CashflowData? _cashflow;
  CategoryStats? _categories;
  List<TxDto>? _txs;
  Object? _error;
  int _generation = 0;
  int _filterVersion = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState()
  {
    super.initState();
    _restore();
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

  Future<void> _restore() async
  {
    final prefs = await _prefs();
    if (prefs != null)
    {
      final mode = prefs.getString(_modePref) == FlowMode.turnover.name ? FlowMode.turnover : FlowMode.net;
      final isConverting = prefs.getBool(_isConvertPref) ?? false;
      final code = prefs.getString(_convertPref) ?? defaultConvertCode;
      _filter = _filter.copyWith(mode: mode, convertTo: () => isConverting ? code : null);
    }
    await _load();
  }

  Future<void> _store() async
  {
    final prefs = await _prefs();
    await prefs?.setString(_modePref, _filter.mode.name);
    await prefs?.setBool(_isConvertPref, _filter.convertTo != null);
    if (_filter.convertTo != null)
    {
      await prefs?.setString(_convertPref, _filter.convertTo!);
    }
  }

  Future<void> _load({bool aIsReset = true}) async
  {
    final generation = ++_generation;
    final filter = _filter;
    final (from, to) = filter.range;
    if (aIsReset)
    {
      setState(()
      {
        _error = null;
        _cashflow = null;
        _categories = null;
        _txs = null;
      });
    }

    try
    {
      final api = ref.read(apiProv);
      final results = await Future.wait([
        api.getCashflow(
          aFrom: from,
          aTo: to,
          aBucket: filter.bucket,
          aAccountId: filter.scope.accountId,
          aOwnerId: filter.scope.ownerId,
          aMode: filter.mode,
          aConvertTo: filter.convertTo,
        ),
        api.getCategoryStats(
          aFrom: from,
          aTo: to,
          aAccountId: filter.scope.accountId,
          aOwnerId: filter.scope.ownerId,
          aMode: filter.mode,
          aConvertTo: filter.convertTo,
        ),
        api.getTransactions(
          aAccountId: filter.scope.accountId,
          aOwnerId: filter.scope.ownerId,
          aFrom: from,
          aTo: to,
          aLimit: _blockLimit,
        ),
      ]);
      if (!mounted || generation != _generation)
      {
        return;
      }
      setState(()
      {
        _error = null;
        _cashflow = results[0] as CashflowData;
        _categories = results[1] as CategoryStats;
        _txs = (results[2] as TxPage).items;
      });
    }
    catch (aError)
    {
      if (mounted && generation == _generation)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _setFilter(FinanceFilter aFilter)
  {
    setState(()
    {
      _filter = aFilter;
      _filterVersion++;
    });
    _store();
    _load();
  }

  Future<void> _refresh() async
  {
    ref
      ..invalidate(walletsProv)
      ..invalidate(bankConnsProv)
      ..invalidate(receiptsProv);
    await _load(aIsReset: false);
  }

  void _openFilters(List<AccountDto> aWallets)
  {
    showFinanceFilterSheet(
      context,
      aFilter: _filter,
      aWallets: aWallets,
      aMyUserId: ref.read(sessionUserIdProv),
      aOnChanged: _setFilter,
    );
  }

  Future<void> _push(String aPath, {Map<String, String> aQuery = const {}}) async
  {
    await context.push(Uri(path: aPath, queryParameters: aQuery.isEmpty ? null : aQuery).toString());
    if (mounted)
    {
      ref
        ..invalidate(walletsProv)
        ..invalidate(receiptsProv);
      await _load(aIsReset: false);
    }
  }

  Future<void> _openDialog(Widget aDialog) async
  {
    final isChanged = await showDialog<bool>(context: context, builder: (_) => aDialog);
    if (isChanged == true && mounted)
    {
      ref.invalidate(walletsProv);
      await _load(aIsReset: false);
    }
  }

  Future<void> _connectBank() => connectBank(context, ref);

  void _openCategory(TxCategory? aCategory)
  {
    _push('/app/transactions', aQuery: {
      ..._filter.query,
      if (aCategory != null) 'category': aCategory.name else 'uncategorized': 'true',
    });
  }

  List<AccountDto> _scopedWallets(List<AccountDto> aWallets)
  {
    final accountId = _filter.scope.accountId;
    final ownerId = _filter.scope.ownerId;
    return aWallets
        .where((aWallet) => aWallet.isActive)
        .where((aWallet) => accountId == null || aWallet.id == accountId)
        .where((aWallet) => ownerId == null || aWallet.userId == ownerId)
        .toList();
  }

  @override
  Widget build(BuildContext aContext)
  {
    super.build(aContext);
    aContext.locale;
    final wallets = ref.watch(walletsProv).valueOrNull ?? const <AccountDto>[];

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        key: const PageStorageKey('home.finance'),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _FilterBarDelegate(child: _buildFilterBar(aContext, wallets)),
          ),
          SliverPadding(
            padding: tabPadding(aContext).copyWith(top: 8),
            sliver: SliverList.list(
              children: [
                _buildBanks(aContext),
                const SizedBox(height: _blockGap),
                _buildWallets(aContext, wallets),
                const SizedBox(height: _blockGap),
                _buildReceipts(aContext),
                const SizedBox(height: _blockGap),
                _buildTransactions(aContext),
                const SizedBox(height: _blockGap),
                _buildCashflow(aContext),
                const SizedBox(height: _blockGap),
                _buildCategories(aContext),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(BuildContext aContext, List<AccountDto> aWallets)
  {
    final padding = tabPadding(aContext);
    final chips = [
      scopeLabel(_filter, aWallets, ref.watch(sessionUserIdProv)),
      _filter.periodLabel(aContext),
      if (_filter.convertTo != null) 'finance.convert_short'.tr(args: [_filter.convertTo!]),
      if (_filter.mode == FlowMode.turnover) 'finance.mode_turnover'.tr(),
    ];

    return ColoredBox(
      color: Theme.of(aContext).scaffoldBackgroundColor,
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding.left, 6, padding.right, 6),
        child: Row(
          children: [
            Expanded(
              child: HorizontalScrollZone(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final chip in chips)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(label: Text(chip), onPressed: () => _openFilters(aWallets)),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'finance.filters'.tr(),
              icon: const Icon(AppIcons.slidersHorizontal, size: 20),
              onPressed: () => _openFilters(aWallets),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loading() => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));

  Widget _buildBanks(BuildContext aContext)
  {
    final connsAsync = ref.watch(bankConnsProv);

    return BlockCard(
      title: 'bank.connections'.tr(),
      onAdd: _connectBank,
      addTooltip: 'bank.connect'.tr(),
      onExpand: () => _push('/app/banks'),
      child: connsAsync.when(
        data: (aConns) => aConns.isEmpty
            ? BlockEmpty('bank.none'.tr())
            : Column(children: [for (final conn in aConns.take(_blockLimit)) BankConnTile(conn: conn, onTap: () => _push('/app/banks'))]),
        loading: _loading,
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(bankConnsProv)),
      ),
    );
  }

  Widget _buildWallets(BuildContext aContext, List<AccountDto> aWallets)
  {
    final scoped = _scopedWallets(aWallets);

    return BlockCard(
      title: 'finance.cards'.tr(),
      onAdd: () => _push('/app/wallets/new'),
      addTooltip: 'wallet.add'.tr(),
      onExpand: () => _push('/app/wallets'),
      child: ref.watch(walletsProv).isLoading && aWallets.isEmpty
          ? _loading()
          : scoped.isEmpty
              ? BlockEmpty('wallet.empty'.tr())
              : Column(
                  children: [
                    for (final wallet in scoped.take(_blockLimit))
                      WalletRow(wallet: wallet, onTap: () => _push('/app/wallets/${wallet.id}')),
                  ],
                ),
    );
  }

  Widget _buildReceipts(BuildContext aContext)
  {
    final receiptsAsync = ref.watch(receiptsProv);

    return BlockCard(
      title: 'sidebar.receipts'.tr(),
      onAdd: () => _push('/app/receipts/new'),
      addTooltip: 'finance.new_receipt'.tr(),
      onExpand: () => _push('/app/receipts'),
      child: receiptsAsync.when(
        data: (aReceipts) => aReceipts.isEmpty
            ? BlockEmpty('finance.no_receipts'.tr())
            : Column(
                children: [
                  for (final receipt in aReceipts.take(_blockLimit))
                    ListTile(
                      onTap: () => _push('/app/receipts/${receipt.id}'),
                      leading: CircleAvatar(
                        backgroundColor: aContext.palette.surfaceMuted,
                        child: Icon(AppIcons.receipt, size: 18, color: aContext.palette.inkSecondary),
                      ),
                      title: Text(receipt.merchantName ?? 'finance.receipt_untitled'.tr(), maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [formatDateTime(aContext, receipt.receiptTs), if (receipt.ownerName != null) receipt.ownerName!].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        formatMoney(aContext, receipt.itemsTotal - receipt.discount, receipt.currCode),
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: aContext.palette.inkPrimary),
                      ),
                    ),
                ],
              ),
        loading: _loading,
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(receiptsProv)),
      ),
    );
  }

  Widget _buildTransactions(BuildContext aContext)
  {
    final txs = _txs;

    return BlockCard(
      title: 'sidebar.transactions'.tr(),
      onAdd: () => _openDialog(const CashEntryDialog(isIncome: true)),
      addTooltip: 'finance.cash_entry'.tr(),
      onExpand: () => _push('/app/transactions', aQuery: _filter.query),
      child: _error != null
          ? ErrorRetry(error: _error!, onRetry: _load)
          : txs == null
              ? _loading()
              : txs.isEmpty
                  ? BlockEmpty('finance.no_transactions'.tr())
                  : Column(
                      children: [
                        for (final tx in txs) TxTile(tx: tx, isFlat: true, onTap: () => _openDialog(TxDetailDialog(tx: tx))),
                      ],
                    ),
    );
  }

  String? _currencyOf(List<String> aCodes)
  {
    final preferred = _filter.convertTo ?? _filter.currCode;
    return aCodes.contains(preferred) ? preferred : aCodes.firstOrNull;
  }

  Widget _currencyChips(List<String> aCodes, String? aSelected)
  {
    if (_filter.convertTo != null || aCodes.length < 2)
    {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Wrap(
        spacing: 6,
        children: [
          for (final code in aCodes)
            ChoiceChip(
              label: Text(code),
              selected: code == aSelected,
              onSelected: (_) => setState(() => _filter = _filter.copyWith(currCode: () => code)),
            ),
        ],
      ),
    );
  }

  Widget _missingRates(BuildContext aContext, List<String> aMissing)
  {
    if (aMissing.isEmpty)
    {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Text(
        'finance.missing_rates'.tr(args: [aMissing.join(', ')]),
        style: TextStyle(fontSize: 12, color: aContext.palette.warning),
      ),
    );
  }

  Widget _buildCashflow(BuildContext aContext)
  {
    final data = _cashflow;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (data == null)
    {
      content = _loading();
    }
    else
    {
      final codes = data.series.map((aSeries) => aSeries.currCode).toList();
      final code = _currencyOf(codes);
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _currencyChips(codes, code),
          _missingRates(aContext, data.missingRates),
          if (code == null)
            BlockEmpty('finance.no_cashflow'.tr())
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: CashflowChart(
                key: ValueKey('cashflow:$code:${_filter.bucket.name}:$_filterVersion'),
                series: data.series.firstWhere((aSeries) => aSeries.currCode == code),
                bucket: _filter.bucket,
              ),
            ),
        ],
      );
    }

    return BlockCard(title: 'finance.cashflow'.tr(), child: content);
  }

  Widget _buildCategories(BuildContext aContext)
  {
    final data = _categories;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (data == null)
    {
      content = _loading();
    }
    else
    {
      final codes = data.series.map((aSeries) => aSeries.currCode).toList();
      final code = _currencyOf(codes);
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _currencyChips(codes, code),
          _missingRates(aContext, data.missingRates),
          if (code == null)
            BlockEmpty('finance.no_cashflow'.tr())
          else
            CategoryView(
              key: ValueKey('categories:$code:$_filterVersion'),
              series: data.series.firstWhere((aSeries) => aSeries.currCode == code),
              onOpenCategory: _openCategory,
            ),
        ],
      );
    }

    return BlockCard(title: 'finance.categories'.tr(), child: content);
  }
}

class _FilterBarDelegate extends SliverPersistentHeaderDelegate
{
  final Widget child;

  _FilterBarDelegate({required this.child});

  @override
  double get minExtent => _filterBarHeight;

  @override
  double get maxExtent => _filterBarHeight;

  @override
  Widget build(BuildContext aContext, double aShrinkOffset, bool aOverlapsContent) => SizedBox.expand(child: child);

  @override
  bool shouldRebuild(covariant _FilterBarDelegate aOld) => true;
}
