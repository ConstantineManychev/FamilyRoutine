import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../common/app_theme.dart';
import 'finance_filter.dart';

const String convertToPref = 'finance.convert_to';
const String isConvertPref = 'finance.is_convert';
const String groupingPref = 'finance.grouping';
const String chartKindPref = 'finance.chart_kind';

Future<SharedPreferences?> financePrefs() async
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

Future<String?> loadConvertTo() async
{
  final prefs = await financePrefs();
  if (prefs == null || !(prefs.getBool(isConvertPref) ?? false))
  {
    return null;
  }
  return prefs.getString(convertToPref) ?? defaultConvertCode;
}

Future<void> storeConvertTo(String? aCode) async
{
  final prefs = await financePrefs();
  await prefs?.setBool(isConvertPref, aCode != null);
  if (aCode != null)
  {
    await prefs?.setString(convertToPref, aCode);
  }
}

Widget _sheetTitle(BuildContext aContext, String aText) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(aText, style: TextStyle(fontWeight: FontWeight.w700, color: aContext.palette.inkPrimary)),
    );

Widget _sheetFrame(BuildContext aContext, String aTitle, List<Widget> aChildren)
{
  final media = MediaQuery.of(aContext);
  return ConstrainedBox(
    constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + media.viewInsets.bottom + media.padding.bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(aTitle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          ...aChildren,
          const SizedBox(height: 16),
          FilledButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.done'.tr())),
        ],
      ),
    ),
  );
}

class ChartSettings
{
  final ChartGrouping grouping;
  final ChartKind kind;

  const ChartSettings({this.grouping = ChartGrouping.day, this.kind = ChartKind.bars});

  ChartSettings copyWith({ChartGrouping? grouping, ChartKind? kind}) =>
      ChartSettings(grouping: grouping ?? this.grouping, kind: kind ?? this.kind);
}

Future<ChartSettings> loadChartSettings() async
{
  final prefs = await financePrefs();
  final grouping = ChartGrouping.values.where((aItem) => aItem.name == prefs?.getString(groupingPref)).firstOrNull;
  final kind = ChartKind.values.where((aItem) => aItem.name == prefs?.getString(chartKindPref)).firstOrNull;
  return ChartSettings(grouping: grouping ?? ChartGrouping.day, kind: kind ?? ChartKind.bars);
}

Future<void> storeChartSettings(ChartSettings aSettings) async
{
  final prefs = await financePrefs();
  await prefs?.setString(groupingPref, aSettings.grouping.name);
  await prefs?.setString(chartKindPref, aSettings.kind.name);
}

Future<void> showChartSettingsSheet(
  BuildContext aContext, {
  required ChartSettings aSettings,
  required ValueChanged<ChartSettings> aOnChanged,
})
{
  return showModalBottomSheet<void>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ChartSettingsSheet(settings: aSettings, onChanged: aOnChanged),
  );
}

class _ChartSettingsSheet extends StatefulWidget
{
  final ChartSettings settings;
  final ValueChanged<ChartSettings> onChanged;

  const _ChartSettingsSheet({required this.settings, required this.onChanged});

  @override
  State<_ChartSettingsSheet> createState() => _ChartSettingsSheetState();
}

class _ChartSettingsSheetState extends State<_ChartSettingsSheet>
{
  late ChartSettings _settings = widget.settings;

  void _apply(ChartSettings aSettings)
  {
    setState(() => _settings = aSettings);
    widget.onChanged(aSettings);
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    return _sheetFrame(aContext, 'finance.chart_settings'.tr(), [
      _sheetTitle(aContext, 'finance.grouping'.tr()),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<ChartGrouping>(
          key: const ValueKey('chart.grouping'),
          showSelectedIcon: false,
          segments: [
            for (final grouping in ChartGrouping.values)
              ButtonSegment(value: grouping, label: Text('finance.grouping_${grouping.name}'.tr())),
          ],
          selected: {_settings.grouping},
          onSelectionChanged: (aValue) => _apply(_settings.copyWith(grouping: aValue.first)),
        ),
      ),
      _sheetTitle(aContext, 'finance.chart_kind'.tr()),
      RadioGroup<ChartKind>(
        groupValue: _settings.kind,
        onChanged: (aValue) => _apply(_settings.copyWith(kind: aValue)),
        child: Column(
          children: [
            for (final kind in ChartKind.values)
              RadioListTile<ChartKind>(
                key: ValueKey('chart.kind.${kind.name}'),
                contentPadding: EdgeInsets.zero,
                value: kind,
                title: Text('finance.chart_kind_${kind.name}'.tr()),
                subtitle: Text('finance.chart_kind_${kind.name}_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ),
          ],
        ),
      ),
    ]);
  }
}

Future<void> showConvertSheet(
  BuildContext aContext, {
  required String? aConvertTo,
  required List<AccountDto> aWallets,
  required ValueChanged<String?> aOnChanged,
})
{
  return showModalBottomSheet<void>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ConvertSheet(convertTo: aConvertTo, wallets: aWallets, onChanged: aOnChanged),
  );
}

class _ConvertSheet extends StatefulWidget
{
  final String? convertTo;
  final List<AccountDto> wallets;
  final ValueChanged<String?> onChanged;

  const _ConvertSheet({required this.convertTo, required this.wallets, required this.onChanged});

  @override
  State<_ConvertSheet> createState() => _ConvertSheetState();
}

class _ConvertSheetState extends State<_ConvertSheet>
{
  late String? _convertTo = widget.convertTo;
  late String _code = widget.convertTo ?? defaultConvertCode;

  void _apply(String? aCode)
  {
    setState(()
    {
      _convertTo = aCode;
      if (aCode != null)
      {
        _code = aCode;
      }
    });
    widget.onChanged(aCode);
  }

  @override
  Widget build(BuildContext aContext)
  {
    final isOn = _convertTo != null;
    return _sheetFrame(aContext, 'finance.list_settings'.tr(), [
      const SizedBox(height: 8),
      SwitchListTile(
        key: const ValueKey('convert.switch'),
        contentPadding: EdgeInsets.zero,
        value: isOn,
        onChanged: (aValue) => _apply(aValue ? _code : null),
        title: Text('finance.convert_switch'.tr()),
        subtitle: Text('finance.convert_switch_hint'.tr(), style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted)),
      ),
      _sheetTitle(aContext, 'finance.convert_currency'.tr()),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final code in convertCurrencies(widget.wallets))
            ChoiceChip(
              key: ValueKey('convert.code.$code'),
              label: Text(code),
              selected: isOn && _code == code,
              onSelected: (_) => _apply(code),
            ),
        ],
      ),
    ]);
  }
}
