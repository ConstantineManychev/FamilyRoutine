import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/common/page_frames.dart';
import 'package:family_routine/ui/finance/category_view.dart';
import 'package:family_routine/ui/home/app_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _phone = Size(390, 844);

Widget _host(Widget aChild, {EdgeInsets aInsets = EdgeInsets.zero, ThemeData? aTheme})
{
  return ProviderScope(
    child: MaterialApp(
      theme: aTheme ?? lightTheme,
      home: Builder(
        builder: (aContext) => MediaQuery(
          data: MediaQuery.of(aContext).copyWith(size: _phone, viewInsets: aInsets),
          child: aChild,
        ),
      ),
    ),
  );
}

void main()
{
  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());

  testWidgets('dictionaries button hides while the keyboard is open', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_phone);
    await aTester.pumpWidget(_host(const AppFrame(child: Scaffold(body: SizedBox.expand()))));
    expect(find.byType(FloatingActionButton), findsOneWidget);

    await aTester.pumpWidget(_host(const AppFrame(child: Scaffold(body: SizedBox.expand())), aInsets: const EdgeInsets.only(bottom: 320)));
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('dialog lists shrink above the keyboard but stay usable', (aTester) async
  {
    late double openHeight;
    late double keyboardHeight;
    await aTester.pumpWidget(_host(Builder(builder: (aContext)
    {
      openHeight = dialogListHeight(aContext, 420);
      return const SizedBox();
    })));
    await aTester.pumpWidget(_host(
      Builder(builder: (aContext)
      {
        keyboardHeight = dialogListHeight(aContext, 420);
        return const SizedBox();
      }),
      aInsets: const EdgeInsets.only(bottom: 340),
    ));
    expect(openHeight, 420);
    expect(keyboardHeight, lessThan(420));
    expect(keyboardHeight, greaterThanOrEqualTo(160));
  });

  testWidgets('list page search filters through the builder and closes back to the full list', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_phone);
    const names = ['Lidl', 'Tesco', 'Aldi'];
    await aTester.pumpWidget(_host(ListPage(
      title: 'Receipts',
      onAdd: () {},
      builder: (_, aQuery) => ListView(
        children: [for (final name in names.where((aName) => aName.toLowerCase().contains(aQuery))) Text(name)],
      ),
    )));

    expect(find.byType(TextField), findsNothing);
    await aTester.tap(find.byTooltip('common.search'));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byType(TextField), 'te');
    await aTester.pump();
    expect(find.text('Tesco'), findsOneWidget);
    expect(find.text('Lidl'), findsNothing);

    await aTester.tap(find.byTooltip('common.close_search'));
    await aTester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Lidl'), findsOneWidget);
    expect(find.byTooltip('common.close'), findsOneWidget);
  });

  testWidgets('category block swipes between the list and the chart in portrait', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_phone);
    final series = CategorySeries(
      currCode: 'EUR',
      incomeTotal: 0,
      expenseTotal: 30,
      items: const [
        CategoryAmount(category: TxCategory.groceries, income: 0, expense: 20, txCount: 2),
        CategoryAmount(category: TxCategory.fuel, income: 0, expense: 10, txCount: 1),
      ],
    );
    await aTester.pumpWidget(_host(
      Scaffold(body: SingleChildScrollView(child: CategoryView(series: series, onOpenCategory: (_) {}))),
      aTheme: violetTheme,
    ));

    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
    await aTester.fling(find.byType(LinearProgressIndicator).first, const Offset(-300, 0), 1200);
    await aTester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await aTester.fling(find.byType(CustomPaint).last, const Offset(300, 0), 1200);
    await aTester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNWidgets(2));
  });

  test('every category maps to a theme color and unknown slots fold into other', ()
  {
    for (final palette in [AppPalette.light, AppPalette.dark, AppPalette.violet])
    {
      expect(categoryColor(palette, TxCategory.groceries), palette.series[0]);
      expect(categoryColor(palette, TxCategory.fuel), palette.seriesOther);
      expect(categoryColor(palette, null), palette.seriesOther);
      expect(palette.seriesAt(42), palette.seriesOther);
    }
  });
}
