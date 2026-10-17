import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/finance/cashflow_chart.dart';
import 'package:family_routine/ui/finance/finance_filter.dart';
import 'package:family_routine/ui/finance/finance_settings.dart';
import 'package:family_routine/ui/finance/transactions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

CashflowSeries _series() => CashflowSeries(
      currCode: 'UAH',
      incomeTotal: 1000,
      expenseTotal: 450,
      points: [
        CashflowPoint(ts: DateTime(2026, 1, 5), income: 0, expense: 150),
        CashflowPoint(ts: DateTime(2026, 1, 12), income: 1000, expense: 0),
        CashflowPoint(ts: DateTime(2026, 1, 19), income: 0, expense: 300),
      ],
    );

TxDto _tx({double? aConverted}) => TxDto(
      id: 't1',
      accountId: 'a1',
      accountName: 'Card',
      currCode: 'UAH',
      amount: -910,
      txTs: DateTime(2026, 1, 5, 10),
      txType: 'expense',
      source: 'bank',
      description: 'Silpo',
      isPending: false,
      isEditable: true,
      convertedAmount: aConverted,
      convertedCurrCode: aConverted == null ? null : 'EUR',
    );

Widget _app(Widget aChild)
{
  return EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'unused',
    assetLoader: const _EnglishLoader(),
    child: Builder(
      builder: (aContext) => MaterialApp(
        locale: aContext.locale,
        localizationsDelegates: aContext.localizationDelegates,
        supportedLocales: aContext.supportedLocales,
        theme: lightTheme,
        home: Scaffold(body: SingleChildScrollView(child: aChild)),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester aTester, Widget aChild, {Size aSize = const Size(900, 900)}) async
{
  aTester.view.physicalSize = aSize;
  aTester.view.devicePixelRatio = 1;
  addTearDown(aTester.view.reset);
  await aTester.pumpWidget(_app(aChild));
  await aTester.pumpAndSettle();
}

void main()
{
  setUpAll(() async
  {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableBuildModes = [];
    await EasyLocalization.ensureInitialized();
  });

  test('running balance adds income and subtracts expenses', ()
  {
    expect(runningBalance(_series().points), [-150, 850, 550]);
  });

  test('buckets end on calendar boundaries', ()
  {
    expect(StatsBucket.week.endOf(DateTime(2026, 1, 26)), DateTime(2026, 2, 2));
    expect(StatsBucket.month.endOf(DateTime(2026, 12, 1)), DateTime(2027, 1, 1));
    expect(StatsBucket.day.endOf(DateTime(2026, 3, 29)), DateTime(2026, 3, 30));
  });

  test('grouping picks the chart bucket', ()
  {
    const filter = FinanceFilter();
    expect(filter.bucket, StatsBucket.day);
    expect(filter.copyWith(grouping: ChartGrouping.week).bucket, StatsBucket.week);
    expect(filter.copyWith(grouping: ChartGrouping.month).bucket, StatsBucket.month);
    final short = filter.copyWith(preset: PeriodPreset.custom, custom: DateTimeRange(start: DateTime(2026, 1, 5), end: DateTime(2026, 1, 5)));
    expect(short.bucket, StatsBucket.hour);
    expect(short.copyWith(grouping: ChartGrouping.month).bucket, StatsBucket.month);
  });

  test('chart scale keeps room above and below zero only when needed', ()
  {
    final positive = ChartScale.of(850, 0);
    expect(positive.top, 1000);
    expect(positive.bottom, 0);
    expect(positive.ticks, [1000, 500]);
    final mixed = ChartScale.of(850, -150);
    expect(mixed.bottom, 200);
  });

  testWidgets('tapping a weekly column opens that week', (aTester) async
  {
    final opened = <(DateTime, DateTime)>[];
    await _pump(
      aTester,
      CashflowChart(
        series: _series(),
        bucket: StatsBucket.week,
        kind: ChartKind.balance,
        onOpenPeriod: (aFrom, aTo) => opened.add((aFrom, aTo)),
      ),
    );
    expect(find.text('Tap a period to open its transactions'), findsOneWidget);
    expect(find.text('+₴550.00'), findsOneWidget);

    final plot = find.byKey(const ValueKey('cashflow.plot'));
    final box = aTester.getRect(plot);
    await aTester.tapAt(Offset(box.left + box.width / 2, box.top + 40));
    await aTester.pumpAndSettle();
    expect(opened.single, (DateTime(2026, 1, 12), DateTime(2026, 1, 19)));
    expect(find.text('+₴850.00'), findsOneWidget);
    expect(find.textContaining('Jan 12 – Jan 18, 2026'), findsOneWidget);
    await aTester.tapAt(Offset(box.right - 5, box.top + 40));
    await aTester.pumpAndSettle();
    expect(opened.last, (DateTime(2026, 1, 19), DateTime(2026, 1, 26)));
  });

  testWidgets('converted transactions show both amounts', (aTester) async
  {
    await _pump(aTester, Column(children: [TxTile(tx: _tx(aConverted: -20)), TxTile(tx: _tx())]));
    expect(find.byKey(const ValueKey('tx.converted.t1')), findsOneWidget);
    expect(find.text('−€20.00'), findsOneWidget);
    expect(find.text('−₴910.00'), findsNWidgets(2));
  });

  testWidgets('list settings switch conversion on and pick a currency', (aTester) async
  {
    final changes = <String?>[];
    await _pump(
      aTester,
      Builder(
        builder: (aContext) => TextButton(
          onPressed: () => showConvertSheet(aContext, aConvertTo: null, aWallets: const [], aOnChanged: changes.add),
          child: const Text('open'),
        ),
      ),
    );
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('convert.switch')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('convert.code.USD')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('convert.switch')));
    await aTester.pumpAndSettle();
    expect(changes, ['EUR', 'USD', null]);
  });

  testWidgets('chart settings change grouping and kind', (aTester) async
  {
    final changes = <ChartSettings>[];
    await _pump(
      aTester,
      Builder(
        builder: (aContext) => TextButton(
          onPressed: () => showChartSettingsSheet(aContext, aSettings: const ChartSettings(), aOnChanged: changes.add),
          child: const Text('open'),
        ),
      ),
    );
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('By month'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('chart.kind.balance')));
    await aTester.pumpAndSettle();
    expect(changes.last.grouping, ChartGrouping.month);
    expect(changes.last.kind, ChartKind.balance);
  });
}
