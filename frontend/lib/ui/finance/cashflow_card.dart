import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'cashflow_chart.dart';

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

class CashflowCard extends ConsumerStatefulWidget
{
  const CashflowCard({super.key});

  @override
  ConsumerState<CashflowCard> createState() => _CashflowCardState();
}

class _CashflowCardState extends ConsumerState<CashflowCard>
{
  CashflowPeriod _period = CashflowPeriod.week;
  String? _accountId;
  String? _currCode;
  List<CashflowSeries>? _series;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
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

  Future<void> _load() async
  {
    setState(()
    {
      _error = null;
      _series = null;
    });

    try
    {
      final (from, to) = _range();
      final series = await ref.read(apiProv).getCashflow(
            aFrom: from,
            aTo: to,
            aBucket: _period.bucket,
            aAccountId: _accountId,
          );
      if (mounted)
      {
        setState(() => _series = series);
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
    final wallets = ref.watch(walletsProv).valueOrNull ?? const <AccountDto>[];
    final series = _series;
    final selected = series == null || series.isEmpty
        ? null
        : series.where((aItem) => aItem.currCode == _currCode).firstOrNull ?? series.first;

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
          Text('finance.cashflow'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: inkPrimary)),
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
                onSelectionChanged: (aValue)
                {
                  setState(() => _period = aValue.first);
                  _load();
                },
              ),
              SizedBox(
                width: 240,
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
                    _load();
                  },
                ),
              ),
              if (series != null && series.length > 1)
                Wrap(
                  spacing: 6,
                  children: series
                      .map((aItem) => ChoiceChip(
                            label: Text(aItem.currCode),
                            selected: aItem.currCode == selected?.currCode,
                            onSelected: (_) => setState(() => _currCode = aItem.currCode),
                          ))
                      .toList(),
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (_error != null)
            ErrorRetry(error: _error!, onRetry: _load)
          else if (series == null)
            const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()))
          else if (selected == null)
            SizedBox(
              height: 120,
              child: Center(child: Text('finance.no_cashflow'.tr(), style: const TextStyle(color: inkMuted))),
            )
          else
            CashflowChart(key: ValueKey('${selected.currCode}-${_period.name}'), series: selected, bucket: _period.bucket),
        ],
      ),
    );
  }
}
