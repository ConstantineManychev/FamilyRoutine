import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/nutrition/add_food_screen.dart';
import 'package:family_routine/ui/nutrition/food_cats_panel.dart';
import 'package:family_routine/ui/planner/plan_content_editor.dart';
import 'package:family_routine/ui/dicts/product_cats.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _macros(String aKcal) => {'kcal': aKcal, 'prot': '3', 'fat': '2', 'carb': '4'};

DictItemDto _food(String aId, String aName, String? aCatId, String aKcal) => DictItemDto.fromJson({
      'id': aId,
      'name': aName,
      'kind': 'food',
      'unit': 'kilogram',
      'cat_id': aCatId,
      'nutrition': {'kcal': aKcal, 'prot': '3', 'fat': '2', 'carb': '4'},
    });

Map<String, dynamic> _dish(String aId, String aName) => {
      'id': aId,
      'name': aName,
      'raw_g': '500',
      'cooked_g': '400',
      'is_cooked_set': true,
      'per_100': _macros('150'),
      'total': _macros('600'),
      'ingredient_count': 1,
      'missing_count': 0,
      'is_shared': false,
      'is_editable': true,
      'updated_ts': '2026-10-15T12:00:00Z',
      'ingredients': const [],
    };

final ProductCatTree _tree = ProductCatTree.fromJson({
  'max_depth': 3,
  'nodes': [
    {'id': 'c_dairy', 'code': 'dairy', 'name': 'Dairy', 'depth': 1},
    {'id': 'c_kefir', 'parent_id': 'c_dairy', 'code': 'dairy_kefir', 'name': 'Kefir', 'depth': 2},
    {'id': 'c_cottage', 'parent_id': 'c_dairy', 'code': 'dairy_cottage', 'name': 'Cottage', 'depth': 2},
    {'id': 'c_grocery', 'code': 'grocery', 'name': 'Grocery', 'depth': 1},
  ],
});

class _PickerApi extends ApiSvc
{
  final List<(String, bool)> searches = [];

  _PickerApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<List<RecentFood>> getRecentFoods({String? aPersonId}) async => [
        RecentFood.fromJson({'source': 'item', 'item_id': 'i1', 'title': 'Kefir 1%', 'grams': '200', 'per_100': _macros('40')}),
        RecentFood.fromJson({'source': 'item', 'item_id': 'i9', 'title': 'Pizza', 'grams': '150', 'per_100': _macros('260')}),
      ];

  @override
  Future<List<Dish>> getDishes({String? aQuery}) async => [Dish.fromJson(_dish('d1', 'Pilaf')), Dish.fromJson(_dish('d2', 'Soup'))];

  @override
  Future<StockFoods> getStockFoods() async => StockFoods.fromJson({
        'items': [
          {'item_id': 'i1', 'cat_id': 'c_kefir'},
          {'item_id': 'i2', 'cat_id': 'c_cottage'},
        ],
        'dish_ids': ['d1'],
      });

  @override
  Future<List<DictItemDto>> getItems({
    String? aQuery,
    int? aLimit,
    String? aBarcode,
    bool aIsMine = false,
    ItemKind? aKind,
    String? aCatId,
    bool aIsInStock = false,
  }) async
  {
    if (aQuery != null)
    {
      searches.add((aQuery, aIsInStock));
    }
    final stocked = [_food('i1', 'Kefir 1%', 'c_kefir', '40'), _food('i2', 'Cottage cheese 5%', 'c_cottage', '120')];
    return aIsInStock ? stocked : [...stocked, _food('i9', 'Pizza', null, '260')];
  }

  @override
  Future<ProductCatTree> getProductCats() async => _tree;

  @override
  Future<CatEstimate> getCatEstimate(String aCatId) async =>
      CatEstimate.fromJson({'cat_id': aCatId, 'per_100': _macros('80'), 'is_ml': false, 'is_in_stock': true});
}

class _Host extends StatefulWidget
{
  final ValueChanged<PickedFood?> onPicked;

  const _Host({required this.onPicked});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host>
{
  @override
  Widget build(BuildContext aContext) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async => widget.onPicked(await pickPlanFood(aContext)),
            child: const Text('open'),
          ),
        ),
      );
}

Widget _localized(Widget aChild, _PickerApi aApi)
{
  return ProviderScope(
    overrides: [
      apiProv.overrideWithValue(aApi),
      peopleProv.overrideWith((aRef) async => const <PersonRef>[]),
    ],
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'unused',
      assetLoader: const _EnglishLoader(),
      child: Builder(
        builder: (aContext) => MaterialApp(
          locale: aContext.locale,
          localizationsDelegates: aContext.localizationDelegates,
          supportedLocales: aContext.supportedLocales,
          theme: lightTheme,
          home: aChild,
        ),
      ),
    ),
  );
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

  test('stock foods know their items, dishes and category counts', ()
  {
    final stock = StockFoods.fromJson({
      'items': [
        {'item_id': 'i1', 'cat_id': 'c_kefir'},
        {'item_id': 'i2', 'cat_id': 'c_cottage'},
        {'item_id': 'i3', 'cat_id': null},
      ],
      'dish_ids': ['d1'],
    });
    expect(stock.hasItem('i3'), isTrue);
    expect(stock.hasItem('i9'), isFalse);
    expect(stock.hasDish('d1'), isTrue);
    expect(stock.hasFood(RecentFood.fromJson({'source': 'dish', 'dish_id': 'd2', 'title': 'Soup'})), isFalse);
    expect(stock.catIds, {'c_kefir', 'c_cottage'});
    expect(stockCountsByCat(_tree, stock), {'c_dairy': 2, 'c_kefir': 1, 'c_cottage': 1});
  });

  test('category plan foods keep the category and grams for the server', ()
  {
    final content = PlanContent.fromJson({
      'foods': [
        {'id': 'f1', 'source': 'item', 'cat_id': 'c_dairy', 'title': 'Dairy', 'grams': '400', 'total': _macros('272')},
      ],
      'total': _macros('272'),
    });
    final draft = PlanContentDraft.of(content);
    expect(draft.foods.single.catId, 'c_dairy');
    expect(draft.foods.single.grams, 400);
    expect(draft.toJson(RoutineStatus.meal)['foods'], [
      {'cat_id': 'c_dairy', 'grams': '400'},
    ]);
    expect(planFoodTitle(_tree, aCatId: 'c_dairy', aTitle: 'Old name'), catLabel(_tree['c_dairy']!));
    expect(planFoodTitle(null, aCatId: 'c_gone', aTitle: 'Old name'), 'Old name');
  });

  testWidgets('food picker opens with the stock filter on and plans a category', (aTester) async
  {
    final api = _PickerApi();
    PickedFood? picked;
    await aTester.pumpWidget(_localized(_Host(onPicked: (aFood) => picked = aFood), api));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();

    final chip = aTester.widget<FilterChip>(find.byKey(const ValueKey('nutrition.stock_only')));
    expect(chip.selected, isTrue);
    expect(find.text('Kefir 1%'), findsOneWidget);
    expect(find.text('Pizza'), findsNothing);
    expect(find.text('In stock'), findsOneWidget);
    expect(find.text('Cottage cheese 5%'), findsOneWidget);

    await aTester.enterText(find.byKey(const ValueKey('nutrition.food_search')), 'pi');
    await aTester.pump(const Duration(seconds: 1));
    await aTester.pumpAndSettle();
    expect(api.searches.last, ('pi', true));
    expect(find.textContaining('Create'), findsNothing);
    await aTester.tap(find.byKey(const ValueKey('nutrition.stock_only')));
    await aTester.pumpAndSettle();
    expect(api.searches.last, ('pi', false));
    expect(find.text('Pizza'), findsOneWidget);
    await aTester.enterText(find.byKey(const ValueKey('nutrition.food_search')), '');
    await aTester.pump(const Duration(seconds: 1));
    await aTester.pumpAndSettle();
    expect(find.text('Pizza'), findsOneWidget);
    expect(find.text('In stock'), findsNothing);

    await aTester.tap(find.byKey(const ValueKey('nutrition.stock_only')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('Dishes'));
    await aTester.pumpAndSettle();
    expect(find.text('Pilaf'), findsOneWidget);
    expect(find.text('Soup'), findsNothing);

    await aTester.tap(find.byKey(const ValueKey('nutrition.tab_cats')));
    await aTester.pumpAndSettle();
    expect(find.text('Dairy'), findsOneWidget);
    expect(find.text('Pantry staples'), findsNothing);
    expect(find.text('in stock: 2'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('nutrition.stock_only')));
    await aTester.pumpAndSettle();
    expect(find.text('Pantry staples'), findsOneWidget);

    await aTester.tap(find.text('Dairy'));
    await aTester.pumpAndSettle();
    expect(find.byKey(const ValueKey('amount.hint')), findsOneWidget);
    await aTester.enterText(find.byKey(const ValueKey('nutrition.amount')), '400');
    await aTester.pump();
    await aTester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await aTester.pumpAndSettle();

    expect(picked?.title, 'Dairy');
    expect(picked?.kcal, 320);
    expect(picked?.payload, {'cat_id': 'c_dairy', 'grams': '400'});
    expect(aTester.takeException(), isNull);
  });

  testWidgets('food picker with categories fits a narrow phone', (aTester) async
  {
    aTester.view.physicalSize = const Size(320, 640);
    aTester.view.devicePixelRatio = 1;
    addTearDown(aTester.view.reset);
    await aTester.pumpWidget(_localized(_Host(onPicked: (_) {}), _PickerApi()));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    await aTester.tap(find.byKey(const ValueKey('nutrition.tab_cats')));
    await aTester.pumpAndSettle();
    expect(find.text('Dairy'), findsOneWidget);
    expect(aTester.takeException(), isNull);
  });

  testWidgets('category foods in a plan read as estimates', (aTester) async
  {
    final api = _PickerApi();
    final draft = PlanContentDraft.of(PlanContent.fromJson({
      'foods': [
        {'id': 'f1', 'source': 'item', 'cat_id': 'c_dairy', 'title': 'Dairy', 'grams': '400', 'total': _macros('272')},
        {'id': 'f2', 'source': 'quick', 'title': 'Tea', 'total': _macros('10')},
      ],
      'total': _macros('282'),
    }));
    await aTester.pumpWidget(_localized(Scaffold(body: PlanContentEditor(category: RoutineStatus.meal, draft: draft)), api));
    await aTester.pumpAndSettle();
    expect(find.text('Dairy'), findsOneWidget);
    expect(find.textContaining('any product of the category'), findsOneWidget);
    expect(find.textContaining('≈'), findsNWidgets(2));
    expect(aTester.takeException(), isNull);
  });
}
