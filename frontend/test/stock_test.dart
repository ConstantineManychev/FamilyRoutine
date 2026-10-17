import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/nutrition/amount_sheet.dart';
import 'package:family_routine/ui/stock/cook_screen.dart';
import 'package:family_routine/ui/stock/stock_format.dart';
import 'package:family_routine/ui/stock/stock_history_screen.dart';
import 'package:family_routine/ui/stock/stock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(320, 640);

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _macros(String aKcal) => {'kcal': aKcal, 'prot': '5', 'fat': '3', 'carb': '20'};

Map<String, dynamic> _lot(
  String aId,
  String aTitle,
  String aQty,
  String aLeft,
  {
    String aKind = 'item',
    String? aItemId,
    String aMeasure = 'g',
    String aSource = 'receipt',
    String aAcquired = '2026-10-10T10:00:00Z',
    bool aIsTouched = false,
    String? aCost,
    String? aKcal,
    String? aExpires,
    bool aIsExpired = false,
  }
) => {
      'id': aId,
      'kind': aKind,
      'item_id': aItemId,
      'dish_id': aKind == 'dish' ? 'd1' : null,
      'batch_id': aKind == 'dish' ? 'b-$aId' : null,
      'title': aTitle,
      'measure': aMeasure,
      'qty': aQty,
      'left_qty': aLeft,
      'cost': aCost,
      'left_cost': aCost,
      'curr_code': aCost == null ? null : 'UAH',
      'source': aSource,
      'receipt_id': null,
      'acquired_ts': aAcquired,
      'is_touched': aIsTouched,
      'piece_g': null,
      'per_100': aKcal == null ? null : _macros(aKcal),
      'expires_on': aExpires,
      'is_expired': aIsExpired,
    };

String _day(int aOffset)
{
  final day = DateTime.now().add(Duration(days: aOffset));
  return '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
}

Map<String, dynamic> _stockJson({String? aFamilyId}) => {
      'family_id': aFamilyId,
      'family_name': aFamilyId == null ? null : 'Home',
      'is_active': aFamilyId == null,
      'lots': [
        _lot('l1', 'Buckwheat', '1000', '1000', aItemId: 'i1', aCost: '54.00', aKcal: '343'),
        _lot('l2', 'Buckwheat', '500', '500', aItemId: 'i1', aAcquired: '2026-10-12T10:00:00Z', aIsTouched: true),
        _lot('l3', 'Milk', '1860', '930', aItemId: 'i2', aMeasure: 'ml', aSource: 'manual', aExpires: _day(1)),
        _lot('l4', 'Pilaf', '800', '500', aKind: 'dish', aSource: 'cooked', aKcal: '187.5', aExpires: _day(-1), aIsExpired: true),
      ],
    };

Map<String, dynamic> _settingsJson() => {
      'active_family_id': null,
      'stores': [
        {'family_id': null, 'family_name': null, 'is_active': true, 'lot_count': 4},
        {'family_id': 'f1', 'family_name': 'Home', 'is_active': false, 'lot_count': 0},
      ],
    };

Map<String, dynamic> _batchJson(String aId, String aKcal, String aLeft) => {
      'id': aId,
      'lot_id': 'lot-$aId',
      'dish_id': 'd1',
      'family_id': null,
      'title': 'Pilaf',
      'cooked_ts': '2026-10-15T12:00:00Z',
      'raw_g': '550',
      'cooked_g': '800',
      'left_g': aLeft,
      'per_100': _macros(aKcal),
      'missing_count': 0,
      'cost': null,
      'curr_code': null,
      'note': null,
      'ingredients': const [],
    };

Map<String, dynamic> _dishJson() => {
      'id': 'd1',
      'name': 'Pilaf',
      'note': null,
      'raw_g': '500',
      'cooked_g': '400',
      'is_cooked_set': true,
      'serving_g': null,
      'servings': null,
      'portion_g': null,
      'per_100': _macros('200'),
      'total': _macros('800'),
      'ingredient_count': 2,
      'missing_count': 0,
      'is_shared': false,
      'is_editable': true,
      'owner_name': null,
      'updated_ts': '2026-10-15T12:00:00Z',
      'ingredients': [
        {'item_id': 'i1', 'item_name': 'Rice', 'unit': 'kilogram', 'piece_g': null, 'grams': '200', 'per_100': _macros('360'), 'total': _macros('720')},
        {'item_id': 'i3', 'item_name': 'Chicken', 'unit': 'kilogram', 'piece_g': null, 'grams': '300', 'per_100': _macros('200'), 'total': _macros('600')},
      ],
    };

class _Cooked
{
  final String dishId;
  final double cookedG;
  final List<double> grams;
  final DateTime? expiresOn;

  const _Cooked(this.dishId, this.cookedG, this.grams, this.expiresOn);
}

class _FakeApi extends ApiSvc
{
  final List<(String, double, WasteReason)> wasted = [];
  final List<String?> activated = [];
  final List<_Cooked> cooked = [];
  final List<StockStoreRef?> loaded = [];
  final List<(String, DateTime?)> expiries = [];

  _FakeApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<StockSettings> getStockSettings() async => StockSettings.fromJson(_settingsJson());

  @override
  Future<StockSettings> saveStockSettings(String? aFamilyId) async
  {
    activated.add(aFamilyId);
    return StockSettings.fromJson(_settingsJson());
  }

  @override
  Future<StockData> getStock({StockStoreRef? aStore}) async
  {
    loaded.add(aStore);
    final familyId = aStore?.familyId;
    return StockData.fromJson(familyId == null ? _stockJson() : {..._stockJson(aFamilyId: familyId), 'lots': const []});
  }

  @override
  Future<StockLot> wasteStockLot(String aId, double aQty, WasteReason aReason, String? aNote) async
  {
    wasted.add((aId, aQty, aReason));
    return StockLot.fromJson(_lot(aId, 'Milk', '1860', '0'));
  }

  @override
  Future<StockLot> setStockLotExpiry(String aId, DateTime? aExpiresOn) async
  {
    expiries.add((aId, aExpiresOn));
    return StockLot.fromJson(_lot(aId, 'Milk', '1860', '930'));
  }

  @override
  Future<Dish> getDish(String aId) async => Dish.fromJson(_dishJson());

  @override
  Future<CookBatch> cookDish({
    required StockStoreRef aStore,
    required String aDishId,
    required double aCookedG,
    required List<CookIngredient> aIngredients,
    String? aNote,
    DateTime? aExpiresOn,
  }) async
  {
    cooked.add(_Cooked(aDishId, aCookedG, aIngredients.map((aItem) => aItem.grams).toList(), aExpiresOn));
    return CookBatch.fromJson(_batchJson('b9', '330', '800'));
  }

  @override
  Future<StockMoves> getStockMoves({StockStoreRef? aStore, StockMoveKind? aKind, DateTime? aFrom, DateTime? aTo, int aLimit = 100}) async =>
      StockMoves.fromJson({
        'moves': [
          {
            'id': 'm1',
            'kind': 'waste',
            'lot_id': 'l3',
            'title': 'Milk',
            'measure': 'ml',
            'qty': '200',
            'cost': '8.00',
            'curr_code': 'UAH',
            'reason': 'spoiled',
            'note': 'Sour',
            'actor_name': 'Bob Stone',
            'created_ts': '2026-10-16T09:00:00Z',
          },
        ],
        'waste_g': '200',
        'waste_pcs': '0',
        'waste_costs': [
          {'curr_code': 'UAH', 'amount': '8.00'},
        ],
      });
}

Widget _localized(Widget Function(BuildContext aContext) aBuild, _FakeApi aApi)
{
  return ProviderScope(
    overrides: [apiProv.overrideWithValue(aApi)],
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'unused',
      assetLoader: const _EnglishLoader(),
      child: Builder(builder: aBuild),
    ),
  );
}

Widget _routed(Widget aScreen, _FakeApi aApi)
{
  final router = GoRouter(
    initialLocation: '/app/screen',
    routes: [
      GoRoute(
        path: '/app',
        builder: (_, __) => const Scaffold(body: Text('home')),
        routes: [GoRoute(path: 'screen', builder: (_, __) => aScreen)],
      ),
    ],
  );
  return _localized(
    (aContext) => MaterialApp.router(
      locale: aContext.locale,
      localizationsDelegates: aContext.localizationDelegates,
      supportedLocales: aContext.supportedLocales,
      theme: lightTheme,
      routerConfig: router,
    ),
    aApi,
  );
}

Widget _plain(Widget aChild, _FakeApi aApi)
{
  return _localized(
    (aContext) => MaterialApp(
      locale: aContext.locale,
      localizationsDelegates: aContext.localizationDelegates,
      supportedLocales: aContext.supportedLocales,
      theme: lightTheme,
      home: Scaffold(body: aChild),
    ),
    aApi,
  );
}

Future<void> _pump(WidgetTester aTester, Widget aApp, {Size aSize = const Size(900, 1400)}) async
{
  aTester.view.physicalSize = aSize;
  aTester.view.devicePixelRatio = 1;
  addTearDown(aTester.view.reset);
  await aTester.pumpWidget(aApp);
  await aTester.pumpAndSettle();
}

DictItemDto _item(Map<String, dynamic> aExtra) => DictItemDto.fromJson({
      'id': 'i1',
      'name': 'Thing',
      'kind': 'food',
      'unit': 'piece',
      'nutrition': {'kcal': '100'},
      ...aExtra,
    });

void main()
{
  setUpAll(() async
  {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableBuildModes = [];
    await EasyLocalization.ensureInitialized();
  });

  test('lots group by product and sum what is left', ()
  {
    final data = StockData.fromJson(_stockJson());
    final items = data.groupsOf(StockKind.item);
    expect(items.map((aGroup) => aGroup.title), ['Buckwheat', 'Milk']);
    expect(items.first.leftQty, 1500);
    expect(items.first.lots.length, 2);
    expect(data.groupsOf(StockKind.dish).single.first.isRemovable, isTrue);
    expect(data.lots[1].isRemovable, isFalse);
    expect(data.lots[0].isRemovable, isFalse);
    expect(data.lots[2].isRemovable, isTrue);
    expect(const StockStoreRef(familyId: 'f1').query, {'family_id': 'f1'});
    expect(StockStoreRef.personal.query, {'is_personal': true});
  });

  test('item cards decide the stock measure', ()
  {
    expect(measureOfItem(_item({'unit': 'kilogram'})), StockMeasure.g);
    expect(measureOfItem(_item({'unit': 'liter'})), StockMeasure.ml);
    final milk = _item({'net_qty': '930', 'net_measure': 'ml'});
    expect(measureOfItem(milk), StockMeasure.ml);
    expect(pieceAmountOf(milk, StockMeasure.ml), 930);
    final eggs = _item({'nutrition': {'kcal': '157', 'piece_g': '60'}});
    expect(measureOfItem(eggs), StockMeasure.g);
    expect(pieceAmountOf(eggs, StockMeasure.g), 60);
    expect(measureOfItem(_item({'kind': 'product', 'nutrition': <String, dynamic>{}})), StockMeasure.pcs);
    expect(measureOfItem(_item({'kind': 'service'})), isNull);
  });

  testWidgets('stock screen shows products, batches and switches the active store', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const StockScreen(), api));

    expect(find.text('Personal stock'), findsWidgets);
    expect(find.byKey(const ValueKey('stock.active')), findsOneWidget);
    expect(find.text('Buckwheat'), findsOneWidget);
    expect(find.textContaining('1,500 g · 2 lots'), findsOneWidget);
    expect(find.text('Pilaf'), findsOneWidget);
    expect(find.textContaining('500 g of 800 g left'), findsOneWidget);

    await aTester.tap(find.byType(DropdownButtonFormField<String>));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('Group stock “Home”').last);
    await aTester.pumpAndSettle();
    expect(api.loaded.last?.familyId, 'f1');
    expect(find.text('No products. Add a receipt with purchases or a product manually.'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('stock.make_active')));
    await aTester.pumpAndSettle();
    expect(api.activated.single, 'f1');
  });

  testWidgets('a lot is written off with a reason and its cost share', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const StockScreen(), api));

    await aTester.tap(find.text('Milk'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('stock.lot_menu.l3')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('Write off as waste'));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('waste.qty')), '931');
    await aTester.pump();
    expect(aTester.widget<ElevatedButton>(find.byKey(const ValueKey('waste.save'))).onPressed, isNull);
    await aTester.enterText(find.byKey(const ValueKey('waste.qty')), '200');
    await aTester.tap(find.byKey(const ValueKey('waste.reason.leftovers')));
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('waste.save')));
    await aTester.pumpAndSettle();
    expect(api.wasted.single, ('l3', 200.0, WasteReason.leftovers));
  });

  testWidgets('cooking scales the recipe, shows stock and sends the real weight', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const CookScreen(dishId: 'd1', store: StockStoreRef.personal), api));

    expect(find.text('Rice'), findsOneWidget);
    expect(find.text('1,500 g in stock'), findsOneWidget);
    expect(find.text('not in stock'), findsOneWidget);
    expect(find.text('Raw weight: 500 g'), findsOneWidget);
    expect(find.textContaining('330 kcal'), findsOneWidget);

    await aTester.tap(find.text('×2'));
    await aTester.pumpAndSettle();
    expect(find.text('Raw weight: 1,000 g'), findsOneWidget);
    await aTester.enterText(find.byKey(const ValueKey('cook.cooked')), '900');
    await aTester.pump();
    await aTester.ensureVisible(find.byKey(const ValueKey('cook.save')));
    await aTester.tap(find.byKey(const ValueKey('cook.save')));
    await aTester.pumpAndSettle();
    expect(api.cooked.single.dishId, 'd1');
    expect(api.cooked.single.cookedG, 900);
    expect(api.cooked.single.grams, [400, 600]);
    expect(api.cooked.single.expiresOn, isNull);
  });

  testWidgets('lots show their best before date and can change it', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const StockScreen(), api));

    expect(find.text('Expires tomorrow'), findsOneWidget);
    expect(find.textContaining('Expired ('), findsOneWidget);
    await aTester.tap(find.text('Milk'));
    await aTester.pumpAndSettle();
    expect(find.text('Expires tomorrow'), findsNWidgets(2));
    await aTester.tap(find.byKey(const ValueKey('stock.lot_menu.l3')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('Best before date'));
    await aTester.pumpAndSettle();
    expect(find.text('Best before: Milk'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('expiry.plus.7')));
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('expiry.save')));
    await aTester.pumpAndSettle();
    final today = DateTime.now();
    expect(api.expiries.single, ('l3', DateTime(today.year, today.month, today.day + 7)));

    await aTester.tap(find.byKey(const ValueKey('stock.lot_menu.l3')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('Best before date'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('expiry.clear')));
    await aTester.pump();
    expect(find.text('Best before: not set'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('expiry.save')));
    await aTester.pumpAndSettle();
    expect(api.expiries.last, ('l3', null));
  });

  testWidgets('a cooked batch gets a best before date', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const CookScreen(dishId: 'd1', store: StockStoreRef.personal), api));
    await aTester.enterText(find.byKey(const ValueKey('cook.cooked')), '400');
    await aTester.pump();
    await aTester.ensureVisible(find.byKey(const ValueKey('expiry.plus.3')));
    await aTester.tap(find.byKey(const ValueKey('expiry.plus.3')));
    await aTester.pump();
    await aTester.ensureVisible(find.byKey(const ValueKey('cook.save')));
    await aTester.tap(find.byKey(const ValueKey('cook.save')));
    await aTester.pumpAndSettle();
    final today = DateTime.now();
    expect(api.cooked.single.expiresOn, DateTime(today.year, today.month, today.day + 3));
  });

  test('days left count calendar days', ()
  {
    final lot = StockLot.fromJson(_lot('x', 'Milk', '1', '1', aExpires: '2026-03-30'));
    expect(lot.daysLeft(DateTime(2026, 3, 29, 23, 30)), 1);
    expect(lot.daysLeft(DateTime(2026, 3, 30, 0, 10)), 0);
    expect(lot.daysLeft(DateTime(2026, 4, 1)), -2);
    expect(StockLot.fromJson(_lot('y', 'Milk', '1', '1')).daysLeft(DateTime(2026, 3, 29)), isNull);
  });

  testWidgets('diary amount sheet takes nutrition from the chosen batch', (aTester) async
  {
    final api = _FakeApi();
    AmountResult? result;
    final dish = Dish.fromJson(_dishJson());
    final batches = [CookBatch.fromJson(_batchJson('b1', '150', '500')), CookBatch.fromJson(_batchJson('b2', '250', '800'))];
    await _pump(
      aTester,
      _plain(
        Builder(
          builder: (aContext) => TextButton(
            onPressed: () async => result = await showAmountSheet(aContext, aTarget: AmountTarget.dish(dish, aBatches: batches), aGrams: 200),
            child: const Text('open'),
          ),
        ),
        api,
      ),
    );
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    expect(find.text('Which batch'), findsOneWidget);
    expect(find.textContaining('300 kcal'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('amount.batch.b2')));
    await aTester.pump();
    expect(find.textContaining('500 kcal'), findsOneWidget);
    await aTester.tap(find.text('Add'));
    await aTester.pumpAndSettle();
    expect(result?.toJson(), {'grams': '200', 'batch_id': 'b2'});

    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('amount.batch.recipe')));
    await aTester.pump();
    expect(find.textContaining('400 kcal'), findsOneWidget);
    await aTester.tap(find.text('Add'));
    await aTester.pumpAndSettle();
    expect(result?.toJson(), {'grams': '200'});
  });

  testWidgets('history sums the waste with reasons and authors', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const StockHistoryScreen(store: StockStoreRef(familyId: 'f1', familyName: 'Home')), api));
    expect(find.text('History: Group stock “Home”'), findsOneWidget);
    expect(find.byKey(const ValueKey('stock.waste_total')), findsOneWidget);
    expect(find.text('200 g · ₴8.00'), findsOneWidget);
    expect(find.textContaining('Spoiled · Bob Stone'), findsOneWidget);
  });

  testWidgets('stock screen fits a narrow phone', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed(const StockScreen(), api), aSize: _narrowPhone);
    expect(aTester.takeException(), isNull);
    await aTester.ensureVisible(find.text('Pilaf'));
    await aTester.pumpAndSettle();
    expect(find.text('Pilaf').hitTestable(), findsOneWidget);
    expect(aTester.takeException(), isNull);
  });
}
