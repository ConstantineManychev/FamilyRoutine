import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/dicts/item_form.dart';
import 'package:family_routine/ui/dicts/product_cats.dart';
import 'package:family_routine/ui/dicts/product_cats_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(320, 640);

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

class _FakeApi extends ApiSvc
{
  _FakeApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<CatPrices> getCatPrices(String aId, {String? aConvertTo, int? aDays, String? aPlaceId}) async =>
      CatPrices.fromJson(_pricesJson);

  @override
  Future<List<DictItemDto>> getItems({
    String? aQuery,
    int? aLimit,
    String? aBarcode,
    bool aIsMine = false,
    ItemKind? aKind,
    String? aCatId,
    bool aIsInStock = false,
  }) async =>
      [
        const DictItemDto(id: 'i1', name: 'Maasdam President 200 g', kind: ItemKind.food, unit: ItemUnit.piece, catId: 'maasdam'),
      ];

  @override
  Future<List<CurrencyDto>> getCurrencies() async => const [CurrencyDto(id: 'c1', code: 'UAH')];

  @override
  Future<List<PlaceDto>> getPlaces() async => const [];
}

final Map<String, dynamic> _treeJson = {
  'max_depth': 3,
  'is_admin': false,
  'nodes': [
    {'id': 'dairy', 'parent_id': null, 'code': 'dairy', 'name': 'Dairy', 'depth': 1, 'item_count': 0, 'owner_kind': 'catalog'},
    {'id': 'cheese', 'parent_id': 'dairy', 'code': 'dairy_cheese', 'name': 'Cheese', 'depth': 2, 'item_count': 1, 'owner_kind': 'catalog'},
    {
      'id': 'maasdam',
      'parent_id': 'cheese',
      'code': null,
      'name': 'Маасдам',
      'depth': 3,
      'item_count': 2,
      'owner_kind': 'me',
      'is_editable': true,
      'is_in_use': false,
    },
    {'id': 'drinks', 'parent_id': null, 'code': 'drinks', 'name': 'Drinks', 'depth': 1, 'item_count': 0, 'owner_kind': 'catalog'},
  ],
};

final Map<String, dynamic> _pricesJson = {
  'rows': [
    {
      'item_id': 'i2',
      'item_name': 'Маасдам весовой с очень длинным названием для узкого экрана',
      'cat_id': 'maasdam',
      'measure': 'g',
      'curr_code': 'UAH',
      'best_100': '42',
      'best_store': 'АТБ',
      'best_branch': null,
      'best_ts': '2026-10-10T10:00:00Z',
      'last_100': '45.5',
      'last_store': 'Сільпо',
      'last_ts': '2026-10-14T10:00:00Z',
      'count': 3,
    },
    {
      'item_id': 'i1',
      'item_name': 'Maasdam President 200 g',
      'cat_id': 'maasdam',
      'measure': 'g',
      'curr_code': 'UAH',
      'best_100': '44.95',
      'best_store': 'АТБ',
      'best_ts': '2026-09-01T10:00:00Z',
      'last_100': '44.95',
      'last_ts': '2026-09-01T10:00:00Z',
      'count': 1,
    },
  ],
  'unmeasured': [
    {'id': 'i3', 'name': 'Маасдам кусок'},
  ],
  'missing_rates': true,
};

Widget _app(Widget aChild, {List<Override> aOverrides = const []})
{
  return ProviderScope(
    overrides: aOverrides,
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

  test('category tree answers paths, branches and depth limits', ()
  {
    final tree = ProductCatTree.fromJson(_treeJson);
    expect(tree.roots().map((aCat) => aCat.id), ['dairy', 'drinks']);
    expect(tree.path('maasdam').map((aCat) => aCat.id), ['dairy', 'cheese', 'maasdam']);
    expect(tree.subtree('dairy').length, 3);
    expect(tree.branchItemCount('dairy'), 3);
    expect(tree.canAddChild('cheese'), isTrue);
    expect(tree.canAddChild('maasdam'), isFalse);
    expect(tree.canAddChild(null), isTrue);
    expect(tree.isWithin('maasdam', 'dairy'), isTrue);
    expect(tree.isWithin('drinks', 'dairy'), isFalse);
    expect(tree['maasdam']!.canChange, isTrue);
  });

  test('every seeded category has a translation in every language', ()
  {
    final migration = File('../backend/migrations/21_product_cats.sql').readAsStringSync();
    final codes = RegExp(r"\('([a-z_]+)', (?:NULL|'[a-z_]+'), '").allMatches(migration).map((aMatch) => aMatch.group(1)!).toSet();
    expect(codes.length, greaterThanOrEqualTo(60));
    for (final locale in ['en', 'ru', 'de', 'fr', 'ja', 'zh'])
    {
      final json = jsonDecode(File('assets/i18n/$locale.json').readAsStringSync()) as Map<String, dynamic>;
      final names = json['product_cats'] as Map<String, dynamic>;
      expect(codes.difference(names.keys.toSet()), isEmpty, reason: locale);
    }
  });

  test('prices and items carry the net weight and the category', ()
  {
    final prices = CatPrices.fromJson(_pricesJson);
    expect(prices.rows.first.best100, 42);
    expect(prices.rows.first.measure, NetMeasure.g);
    expect(prices.unmeasured.single.name, 'Маасдам кусок');
    expect(prices.isMissingRates, isTrue);

    final item = DictItemDto.fromJson({
      'id': 'i1',
      'name': 'Red Bull',
      'kind': 'food',
      'unit': 'piece',
      'net_qty': '250',
      'net_measure': 'ml',
      'cat_id': 'drinks',
    });
    expect(item.netQty, 250);
    expect(item.netMeasure, NetMeasure.ml);
    expect(item.catId, 'drinks');
    expect(
      DictItemDto.payload('Red Bull', ItemKind.food, ItemUnit.piece, aNetQty: 250, aNetMeasure: NetMeasure.ml, aCatId: 'drinks'),
      {'name': 'Red Bull', 'kind': 'food', 'unit': 'piece', 'net_qty': '250.0', 'net_measure': 'ml', 'cat_id': 'drinks'},
    );
    final info = ProductInfo.fromJson({'net_qty': '500', 'net_measure': 'g', 'nutrition': {'piece_g': '125'}});
    expect(info.netQty, 500);
    expect(info.nutrition.pieceG, 125);
  });

  testWidgets('item drafts take the net weight from Open Food Facts', (aTester) async
  {
    await aTester.pumpWidget(_app(const SizedBox()));
    await aTester.pumpAndSettle();
    final draft = ItemDraft(aName: 'Yogurt')
      ..kind = ItemKind.food
      ..unit = ItemUnit.kilogram;
    draft.applyProduct(const ProductInfo(netQty: 500, netMeasure: NetMeasure.g, nutrition: NutritionData(pieceG: 125)));
    expect(draft.unit, ItemUnit.piece);
    expect(draft.netCtrl.text, '500');
    expect(draft.pieceCtrl.text, '125');
    expect(draft.payload()['net_qty'], '500.0');

    draft.netCtrl.text = '0';
    expect(draft.validate(), 'items.net_invalid'.tr());
    draft.unit = ItemUnit.kilogram;
    expect(draft.validate(), isNull);
    expect(draft.payload().containsKey('net_qty'), isFalse);
    draft.dispose();
  });

  testWidgets('strangers may only fill empty fields and send just those', (aTester) async
  {
    await aTester.pumpWidget(_app(const SizedBox()));
    await aTester.pumpAndSettle();
    const foreign = DictItemDto(
      id: 'i9',
      name: 'Cheese from a receipt',
      kind: ItemKind.food,
      unit: ItemUnit.piece,
      nutrition: NutritionData(kcal: 350),
      catId: 'cheese',
    );
    final access = ItemFieldAccess.forItem(foreign);
    expect(access.isKcal, isFalse);
    expect(access.isFat, isTrue);
    expect(access.isNet, isTrue);
    expect(access.isCat, isFalse);
    expect(access.isAny, isTrue);

    const owned = DictItemDto(
      id: 'i8',
      name: 'Mine',
      kind: ItemKind.food,
      unit: ItemUnit.piece,
      netQty: 200,
      netMeasure: NetMeasure.g,
      ownerKind: ItemOwnerKind.me,
      isEditable: true,
      isInUse: true,
    );
    final ownedAccess = ItemFieldAccess.forItem(owned);
    expect(ownedAccess.isKcal, isTrue);
    expect(ownedAccess.isNet, isFalse);
    expect(ownedAccess.isCat, isTrue);
    expect(ItemFieldAccess.forItem(null).isNet, isTrue);

    final draft = ItemDraft()..load(foreign);
    draft.fatCtrl.text = '27';
    draft.netCtrl.text = '200';
    draft.kcalCtrl.text = '999';
    expect(draft.fillPayload(foreign), {
      'nutrition': {'kcal': null, 'prot': null, 'fat': '27.0', 'carb': null, 'piece_g': null},
      'net_qty': '200.0',
      'net_measure': 'g',
    });
    draft.dispose();
  });

  testWidgets('category label prefers the translation of seeded nodes', (aTester) async
  {
    await aTester.pumpWidget(_app(const SizedBox()));
    await aTester.pumpAndSettle();
    final tree = ProductCatTree.fromJson(_treeJson);
    expect(catLabel(tree['cheese']!), 'Cheese');
    expect(catPathLabel(tree, 'maasdam'), 'Dairy › Cheese › Маасдам');
    expect(catLevelLabel(3), 'Type');
    expect(catLevelLabel(4), 'Level 4');
  });

  testWidgets('category screen ranks prices and fits a narrow phone', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));

    await aTester.pumpWidget(_app(
      const ProductCatScreen(catId: 'maasdam'),
      aOverrides: [
        apiProv.overrideWithValue(_FakeApi()),
        productCatsProv.overrideWith((aRef) async => ProductCatTree.fromJson(_treeJson)),
      ],
    ));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.text('Best price per 100 g / 100 ml'), findsOneWidget);
    expect(find.text('Per 100 g'), findsOneWidget);
    expect(find.textContaining('42.00'), findsOneWidget);
    expect(find.textContaining('latest'), findsOneWidget);
    expect(find.text('Маасдам кусок'), findsOneWidget);
    expect(find.text('Some prices have no exchange rate and were skipped.'), findsOneWidget);

    await aTester.drag(find.byType(ListView).first, const Offset(0, -600));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.text('Items in this branch'), findsOneWidget);
  });
}
