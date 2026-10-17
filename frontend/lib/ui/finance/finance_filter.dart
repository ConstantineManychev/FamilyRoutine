import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'wallet_scope.dart';

const String defaultConvertCode = 'EUR';
const Duration _hourlyLimit = Duration(days: 2);

enum PeriodPreset { week, month, monthToDate, quarter, custom }

@immutable
class FinanceFilter
{
  final WalletScope scope;
  final PeriodPreset preset;
  final DateTimeRange? custom;
  final FlowMode mode;
  final String? convertTo;
  final String? currCode;
  final ChartGrouping grouping;

  const FinanceFilter({
    this.scope = const WalletScope(null),
    this.preset = PeriodPreset.month,
    this.custom,
    this.mode = FlowMode.net,
    this.convertTo,
    this.currCode,
    this.grouping = ChartGrouping.day,
  });

  (DateTime, DateTime) get range
  {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    DateTime daysBack(int aDays) => DateTime(tomorrow.year, tomorrow.month, tomorrow.day - aDays);

    return switch (preset)
    {
      PeriodPreset.week => (daysBack(7), tomorrow),
      PeriodPreset.month => (daysBack(30), tomorrow),
      PeriodPreset.monthToDate => (DateTime(now.year, now.month), tomorrow),
      PeriodPreset.quarter => (daysBack(90), tomorrow),
      PeriodPreset.custom => (
          DateTime(custom!.start.year, custom!.start.month, custom!.start.day),
          DateTime(custom!.end.year, custom!.end.month, custom!.end.day + 1),
        ),
    };
  }

  StatsBucket get bucket
  {
    final (from, to) = range;
    return switch (grouping)
    {
      ChartGrouping.week => StatsBucket.week,
      ChartGrouping.month => StatsBucket.month,
      ChartGrouping.day => to.difference(from) <= _hourlyLimit ? StatsBucket.hour : StatsBucket.day,
    };
  }

  Map<String, String> get query
  {
    final (from, to) = range;
    return {
      ...scope.query,
      'from': from.toUtc().toIso8601String(),
      'to': to.toUtc().toIso8601String(),
    };
  }

  String periodLabel(BuildContext aContext)
  {
    if (preset != PeriodPreset.custom)
    {
      return 'finance.preset_${preset.name}'.tr();
    }
    final locale = aContext.locale.toLanguageTag();
    final format = DateFormat.MMMd(locale);
    final range = custom!;
    return DateUtils.isSameDay(range.start, range.end)
        ? format.format(range.start)
        : '${format.format(range.start)} – ${format.format(range.end)}';
  }

  FinanceFilter copyWith({
    WalletScope? scope,
    PeriodPreset? preset,
    DateTimeRange? custom,
    FlowMode? mode,
    String? Function()? convertTo,
    String? Function()? currCode,
    ChartGrouping? grouping,
  })
  {
    return FinanceFilter(
      scope: scope ?? this.scope,
      preset: preset ?? this.preset,
      custom: custom ?? this.custom,
      mode: mode ?? this.mode,
      convertTo: convertTo == null ? this.convertTo : convertTo(),
      currCode: currCode == null ? this.currCode : currCode(),
      grouping: grouping ?? this.grouping,
    );
  }
}

List<String> convertCurrencies(List<AccountDto> aWallets)
{
  final codes = <String>{defaultConvertCode, 'UAH', 'USD', ...aWallets.map((aWallet) => aWallet.currCode)}
    ..removeWhere((aCode) => aCode.isEmpty);
  return codes.toList()..sort();
}

String scopeLabel(FinanceFilter aFilter, List<AccountDto> aWallets, String? aMyUserId)
{
  final ownerId = aFilter.scope.ownerId;
  final accountId = aFilter.scope.accountId;
  if (accountId != null)
  {
    final wallet = aWallets.where((aWallet) => aWallet.id == accountId).firstOrNull;
    return wallet == null ? 'finance.all_wallets'.tr() : walletLabel(wallet);
  }
  if (ownerId != null)
  {
    if (ownerId == aMyUserId)
    {
      return 'finance.my_wallets'.tr();
    }
    final owner = aWallets.where((aWallet) => aWallet.userId == ownerId).firstOrNull?.ownerName;
    return owner == null ? 'finance.all_wallets'.tr() : 'finance.owner_wallets'.tr(args: [owner]);
  }
  return 'finance.all_wallets'.tr();
}

Future<void> showFinanceFilterSheet(
  BuildContext aContext, {
  required FinanceFilter aFilter,
  required List<AccountDto> aWallets,
  required String? aMyUserId,
  required ValueChanged<FinanceFilter> aOnChanged,
})
{
  return showModalBottomSheet<void>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _FilterSheet(filter: aFilter, wallets: aWallets, myUserId: aMyUserId, onChanged: aOnChanged),
  );
}

class _FilterSheet extends StatefulWidget
{
  final FinanceFilter filter;
  final List<AccountDto> wallets;
  final String? myUserId;
  final ValueChanged<FinanceFilter> onChanged;

  const _FilterSheet({required this.filter, required this.wallets, required this.myUserId, required this.onChanged});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet>
{
  late FinanceFilter _filter = widget.filter;

  void _apply(FinanceFilter aFilter)
  {
    setState(() => _filter = aFilter);
    widget.onChanged(aFilter);
  }

  Future<void> _pickCustom() async
  {
    final now = DateTime.now();
    final (from, to) = _filter.range;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now,
      initialDateRange: DateTimeRange(start: from, end: to.subtract(const Duration(days: 1)).isAfter(now) ? now : to.subtract(const Duration(days: 1))),
    );
    if (picked != null && mounted)
    {
      _apply(_filter.copyWith(preset: PeriodPreset.custom, custom: picked));
    }
  }

  List<String> get _currencies => convertCurrencies(widget.wallets);

  Widget _title(BuildContext aContext, String aText) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(aText, style: TextStyle(fontWeight: FontWeight.w700, color: aContext.palette.inkPrimary)),
      );

  @override
  Widget build(BuildContext aContext)
  {
    final media = MediaQuery.of(aContext);
    final convertTo = _filter.convertTo;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + media.viewInsets.bottom + media.padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('finance.filters'.tr(), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            _title(aContext, 'finance.wallet'.tr()),
            DropdownButtonFormField<String?>(
              initialValue: _filter.scope.value,
              isExpanded: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: walletScopeItems(widget.wallets, widget.myUserId),
              onChanged: (aValue) => _apply(_filter.copyWith(scope: WalletScope(aValue))),
            ),
            _title(aContext, 'finance.period'.tr()),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in PeriodPreset.values.where((aPreset) => aPreset != PeriodPreset.custom))
                  ChoiceChip(
                    label: Text('finance.preset_${preset.name}'.tr()),
                    selected: _filter.preset == preset,
                    onSelected: (_) => _apply(_filter.copyWith(preset: preset)),
                  ),
                ChoiceChip(
                  avatar: const Icon(AppIcons.calendarRange, size: 16),
                  label: Text(_filter.preset == PeriodPreset.custom ? _filter.periodLabel(aContext) : 'finance.preset_custom'.tr()),
                  selected: _filter.preset == PeriodPreset.custom,
                  onSelected: (_) => _pickCustom(),
                ),
              ],
            ),
            _title(aContext, 'finance.currency'.tr()),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text('finance.no_conversion'.tr()),
                  selected: convertTo == null,
                  onSelected: (_) => _apply(_filter.copyWith(convertTo: () => null)),
                ),
                for (final code in _currencies)
                  ChoiceChip(
                    label: Text('finance.convert_short'.tr(args: [code])),
                    selected: convertTo == code,
                    onSelected: (_) => _apply(_filter.copyWith(convertTo: () => code)),
                  ),
              ],
            ),
            _title(aContext, 'finance.mode'.tr()),
            SegmentedButton<FlowMode>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: FlowMode.net, label: Text('finance.mode_net'.tr())),
                ButtonSegment(value: FlowMode.turnover, label: Text('finance.mode_turnover'.tr())),
              ],
              selected: {_filter.mode},
              onSelectionChanged: (aValue) => _apply(_filter.copyWith(mode: aValue.first)),
            ),
            const SizedBox(height: 8),
            Text(
              _filter.mode == FlowMode.net ? 'finance.mode_net_hint'.tr() : 'finance.mode_turnover_hint'.tr(),
              style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.done'.tr())),
          ],
        ),
      ),
    );
  }
}
