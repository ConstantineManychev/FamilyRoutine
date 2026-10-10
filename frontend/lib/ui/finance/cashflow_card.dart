import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'cashflow_chart.dart';
import 'category_breakdown.dart';

const String _modePref = 'finance.mode';
const String _convertPref = 'finance.convert_to';
const String _isConvertPref = 'finance.is_convert';
const String _defaultConvertCode = 'EUR';

enum CashflowPeriod
{
  day(StatsBucket.hour, 1),
  week(StatsBucket.day, 7),
  month(StatsBucket.day, 30),
  quarter(StatsBucket.day, 90);

  final StatsBucket bucket;
  final int days;

  const CashflowPeriod(this.bucket, this.days);
}

enum FinanceView { chart, categories }

class CashflowCard extends ConsumerStatefulWidget
{
  final Widget? menu;

  const CashflowCard({super.key, this.menu});

  @override
  ConsumerState<CashflowCard> createState() => _CashflowCardState();
}

class _CashflowCardState extends ConsumerState<CashflowCard>
{
  CashflowPeriod _period = CashflowPeriod.week;
  FinanceView _view = FinanceView.chart;
  FlowMode _mode = FlowMode.net;
  bool _isConverting = false;
  String _convertCode = _defaultConvertCode;
  String? _accountId;
  String? _currCode;
  CashflowData? _cashflow;
  CategoryStats? _categories;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _restorePrefs();
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

  Future<void> _restorePrefs() async
  {
    final prefs = await _prefs();
    if (prefs != null)
    {
      _mode = prefs.getString(_modePref) == FlowMode.turnover.name ? FlowMode.turnover : FlowMode.net;
      _isConverting = prefs.getBool(_isConvertPref) ?? false;
      _convertCode = prefs.getString(_convertPref) ?? _defaultConvertCode;
    }
    if (mounted)
    {
      _load();
    }
  }

  Future<void> _savePrefs() async
  {
    final prefs = await _prefs();
    await prefs?.setString(_modePref, _mode.name);
    await prefs?.setBool(_isConvertPref, _isConverting);
    await prefs?.setString(_convertPref, _convertCode);
  }

  (DateTime, DateTime) _range()
  {
    final now = DateTime.now();

    if (_period.bucket == StatsBucket.hour)
    {
      final hourStart = DateTime(now.year, now.month, now.day, now.hour);
      return (hourStart.subtract(const Duration(hours: 23)), hourStart.add(const Duration(hours: 1)));
    }

    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    return (DateTime(tomorrow.year, tomorrow.month, tomorrow.day - _period.days), tomorrow);
  }

  String? get _convertTo => _isConverting ? _convertCode : null;

  Future<void> _load() async
  {
    setState(()
    {
      _error = null;
      _cashflow = null;
      _categories = null;
    });

    try
    {
      final api = ref.read(apiProv);
      final (from, to) = _range();
      if (_view == FinanceView.chart)
      {
        final data = await api.getCashflow(
              aFrom: from,
              aTo: to,
              aBucket: _period.bucket,
              aAccountId: _accountId,
              aMode: _mode,
              aConvertTo: _convertTo,
            );
        if (mounted)
        {
          setState(() => _cashflow = data);
        }
      }
      else
      {
        final data = await api.getCategoryStats(
              aFrom: from,
              aTo: to,
              aAccountId: _accountId,
              aMode: _mode,
              aConvertTo: _convertTo,
            );
        if (mounted)
        {
          setState(() => _categories = data);
        }
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

  void _update(VoidCallback aChange)
  {
    setState(aChange);
    _savePrefs();
    _load();
  }

  void _openCategory(TxCategory? aCategory)
  {
    final (from, to) = _range();
    final query = {
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
      if (aCategory != null) 'category': aCategory.name else 'uncategorized': 'true',
      if (_accountId != null) 'account_id': _accountId!,
    };
    context.go(Uri(path: '/app/transactions', queryParameters: query).toString());
  }

  List<String> _currencyOptions(List<AccountDto> aWallets, List<String> aSeriesCodes)
  {
    final codes = <String>{_defaultConvertCode, 'UAH', 'USD', ...aWallets.map((aWallet) => aWallet.currCode), ...aSeriesCodes}
      ..removeWhere((aCode) => aCode.isEmpty);
    return codes.toList()..sort();
  }

  @override
  Widget build(BuildContext aContext)
  {
    final wallets = ref.watch(walletsProv).valueOrNull ?? const <AccountDto>[];
    final cashflowSeries = _cashflow?.series;
    final categorySeries = _categories?.series;
    final seriesCodes = _view == FinanceView.chart
        ? (cashflowSeries ?? const []).map((aItem) => aItem.currCode).toList()
        : (categorySeries ?? const []).map((aItem) => aItem.currCode).toList();
    final selectedCode = seriesCodes.contains(_currCode) ? _currCode : seriesCodes.firstOrNull;
    final missingRates = (_view == FinanceView.chart ? _cashflow?.missingRates : _categories?.missingRates) ?? const [];
    final isLoading = _view == FinanceView.chart ? _cashflow == null : _categories == null;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('finance.cashflow'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: inkPrimary)),
                    SegmentedButton<FinanceView>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: FinanceView.chart, icon: const Icon(AppIcons.chartColumn, size: 16), label: Text('finance.view_chart'.tr())),
                        ButtonSegment(value: FinanceView.categories, icon: const Icon(AppIcons.listChecks, size: 16), label: Text('finance.view_categories'.tr())),
                      ],
                      selected: {_view},
                      onSelectionChanged: (aValue) => _update(() => _view = aValue.first),
                    ),
                  ],
                ),
              ),
              if (widget.menu != null) widget.menu!,
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<CashflowPeriod>(
                showSelectedIcon: false,
                segments: CashflowPeriod.values
                    .map((aPeriod) => ButtonSegment(value: aPeriod, label: Text('finance.period_${aPeriod.name}'.tr())))
                    .toList(),
                selected: {_period},
                onSelectionChanged: (aValue) => _update(() => _period = aValue.first),
              ),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<String?>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: 'finance.wallet'.tr(), border: const OutlineInputBorder(), isDense: true),
                  items: [
                    DropdownMenuItem<String?>(value: null, child: Text('finance.all_wallets'.tr())),
                    ...wallets.map((aWallet) => DropdownMenuItem<String?>(value: aWallet.id, child: Text(aWallet.name))),
                  ],
                  onChanged: (aValue) => _update(() => _accountId = aValue),
                ),
              ),
              SegmentedButton<FlowMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: FlowMode.net, label: Text('finance.mode_net'.tr())),
                  ButtonSegment(value: FlowMode.turnover, label: Text('finance.mode_turnover'.tr())),
                ],
                selected: {_mode},
                onSelectionChanged: (aValue) => _update(() => _mode = aValue.first),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _isConverting,
                    onChanged: (aValue) => _update(() => _isConverting = aValue ?? false),
                  ),
                  GestureDetector(
                    onTap: () => _update(() => _isConverting = !_isConverting),
                    child: Text('finance.convert_to'.tr()),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: _convertCode,
                    isDense: true,
                    items: _currencyOptions(wallets, seriesCodes)
                        .map((aCode) => DropdownMenuItem(value: aCode, child: Text(aCode)))
                        .toList(),
                    onChanged: (aValue) => _update(()
                    {
                      _convertCode = aValue ?? _defaultConvertCode;
                      _isConverting = true;
                    }),
                  ),
                ],
              ),
              if (!_isConverting && seriesCodes.length > 1)
                Wrap(
                  spacing: 6,
                  children: seriesCodes
                      .map((aCode) => ChoiceChip(
                            label: Text(aCode),
                            selected: aCode == selectedCode,
                            onSelected: (_) => setState(() => _currCode = aCode),
                          ))
                      .toList(),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _mode == FlowMode.net ? 'finance.mode_net_hint'.tr() : 'finance.mode_turnover_hint'.tr(),
            style: const TextStyle(fontSize: 12, color: inkMuted),
          ),
          if (missingRates.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'finance.missing_rates'.tr(args: [missingRates.join(', ')]),
              style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
            ),
          ],
          const SizedBox(height: 16),
          if (_error != null)
            ErrorRetry(error: _error!, onRetry: _load)
          else if (isLoading)
            const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()))
          else if (selectedCode == null)
            SizedBox(
              height: 120,
              child: Center(child: Text('finance.no_cashflow'.tr(), style: const TextStyle(color: inkMuted))),
            )
          else if (_view == FinanceView.chart)
            CashflowChart(
              key: ValueKey('$selectedCode-${_period.name}-${_mode.name}'),
              series: cashflowSeries!.firstWhere((aItem) => aItem.currCode == selectedCode),
              bucket: _period.bucket,
            )
          else
            CategoryBreakdown(
              key: ValueKey('$selectedCode-${_period.name}-${_mode.name}'),
              series: categorySeries!.firstWhere((aItem) => aItem.currCode == selectedCode),
              onOpenCategory: _openCategory,
            ),
        ],
      ),
    );
  }
}
