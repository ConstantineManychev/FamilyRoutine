import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/nutrition/amount_sheet.dart';
import 'package:family_routine/ui/nutrition/dish_editor_screen.dart';
import 'package:family_routine/ui/nutrition/nutrition_format.dart';
import 'package:family_routine/ui/nutrition/nutrition_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

Widget _localized(Widget aChild)
{
  return ProviderScope(
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
          home: Scaffold(body: aChild),
        ),
      ),
    ),
  );
}

Map<String, dynamic> _macros(String aKcal, String aProt, String aFat, String aCarb) =>
    {'kcal': aKcal, 'prot': aProt, 'fat': aFat, 'carb': aCarb};

Map<String, dynamic> _dayJson({bool aHasNorm = true}) => {
      'date': '2026-10-16',
      'total': _macros('765.7', '42.1', '30.5', '90'),
      'meals': [
        {
          'meal': 'breakfast',
          'total': _macros('302.7', '14', '12.7', '0.8'),
          'entries': [
            {
              'id': 'm1',
              'date': '2026-10-16',
              'meal': 'breakfast',
              'source': 'item',
              'item_id': 'i1',
              'dish_id': null,
              'title': 'Egg',
              'grams': '110',
              'portions': '2',
              'portion_g': '55',
              'is_ml': false,
              'per_100': _macros('157', '12.7', '11.5', '0.7'),
              'total': _macros('172.7', '14', '12.7', '0.8'),
              'created_ts': '2026-10-16T07:00:00Z',
            },
          ],
        },
        {'meal': 'lunch', 'total': _macros('0', '0', '0', '0'), 'entries': const []},
        {
          'meal': 'snack',
          'total': _macros('120', '0', '6', '0'),
          'entries': [
            {
              'id': 'm2',
              'date': '2026-10-16',
              'meal': 'snack',
              'source': 'quick',
              'title': null,
              'grams': null,
              'portions': null,
              'portion_g': null,
              'is_ml': false,
              'per_100': null,
              'total': _macros('120', '0', '6', '0'),
              'created_ts': '2026-10-16T12:00:00Z',
            },
          ],
        },
      ],
      'norm': aHasNorm
          ? {'target': _macros('1774', '96', '59', '255'), 'bmr': '1290', 'activity': 'light', 'weight_kg': '60'}
          : null,
      'norm_gaps': aHasNorm ? const [] : const ['weight', 'sex', 'unknown'],
      'workout_kcal': '350',
    };

void main()
{
  setUpAll(() async
  {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableBuildModes = [];
    await EasyLocalization.ensureInitialized();
  });

  test('nutrition day parses meals, snapshots and the norm', ()
  {
    final day = NutritionDay.fromJson(_dayJson());
    expect(day.date, DateTime(2026, 10, 16));
    expect(day.total.kcal, 765.7);
    expect(day.group(MealSlot.breakfast).entries.single.portions, 2);
    expect(day.group(MealSlot.breakfast).entries.single.per100!.kcal, 157);
    expect(day.group(MealSlot.dinner).entries, isEmpty);
    expect(day.group(MealSlot.snack).entries.single.source, MealSource.quick);
    expect(day.norm!.target.prot, 96);
    expect(day.norm!.activity, ActivityLevel.light);
    expect(day.workoutKcal, 350);

    final gaps = NutritionDay.fromJson(_dayJson(aHasNorm: false));
    expect(gaps.norm, isNull);
    expect(gaps.normGaps, [NormGap.weight, NormGap.sex]);
  });

  test('dish math uses the cooked weight like the server', ()
  {
    const buckwheat = DishIngredient(itemId: 'b', itemName: 'Buckwheat', grams: 200, per100: Macros(kcal: 343, prot: 13.3, fat: 3.4, carb: 62.1));
    const salt = DishIngredient(itemId: 's', itemName: 'Salt', grams: 4);
    final boiled = DishMath.compute([buckwheat, salt], aCookedG: 600, aServings: 3);
    expect(boiled.rawG, 204);
    expect(boiled.per100.kcal, closeTo(114.33, 0.01));
    expect(boiled.per100.carb, closeTo(20.7, 0.01));
    expect(boiled.portionG, 200);
    expect(boiled.missingCount, 1);

    final raw = DishMath.compute([buckwheat]);
    expect(raw.cookedG, 200);
    expect(raw.per100.kcal, closeTo(343, 0.001));
    expect(DishMath.compute([buckwheat], aServingG: 250).portionG, 250);
  });

  testWidgets('dish drafts reject impossible cooked weights and portions', (aTester) async
  {
    await aTester.pumpWidget(_localized(const SizedBox()));
    await aTester.pumpAndSettle();
    const ingredient = DishIngredient(itemId: 'b', itemName: 'Buckwheat', grams: 200);
    expect(const DishDraft(ingredients: [ingredient], cookedG: 600).validate(), isNull);
    expect(const DishDraft(ingredients: []).validate(), 'nutrition.err_no_ingredients'.tr());
    expect(const DishDraft(ingredients: [ingredient], cookedG: 10).validate(), 'nutrition.err_cooked'.tr());
    expect(const DishDraft(ingredients: [ingredient], cookedG: 2500).validate(), 'nutrition.err_cooked'.tr());
    expect(const DishDraft(ingredients: [ingredient], mode: PortionMode.count, servings: 0).validate(), 'nutrition.err_servings'.tr());
    expect(const DishDraft(ingredients: [ingredient], mode: PortionMode.weight).validate(), 'nutrition.err_serving'.tr());
    expect(
      const DishDraft(ingredients: [DishIngredient(itemId: 'x', itemName: 'X', grams: 0)]).validate(),
      'nutrition.err_ingredient_grams'.tr(),
    );
  });

  test('amount results send either grams or portions', ()
  {
    expect(const AmountResult(meal: MealSlot.lunch, grams: 150).toJson(), {'meal': 'lunch', 'grams': '150'});
    expect(const AmountResult(meal: MealSlot.dinner, portions: 1.5).toJson(), {'meal': 'dinner', 'portions': '1.5'});
    expect(amountText(0.25), '0.25');
    expect(amountText(2), '2');
    expect(parseAmountText('1,5'), 1.5);
    expect(MealSlot.forHour(7), MealSlot.breakfast);
    expect(MealSlot.forHour(13), MealSlot.lunch);
    expect(MealSlot.forHour(17), MealSlot.snack);
    expect(MealSlot.forHour(21), MealSlot.dinner);
  });

  testWidgets('amount sheet converts between grams and portions and returns the chosen meal', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));
    AmountResult? result;

    await aTester.pumpWidget(_localized(Builder(
      builder: (aContext) => Center(
        child: ElevatedButton(
          onPressed: () async => result = await showAmountSheet(
            aContext,
            aTarget: const AmountTarget(title: 'Buckwheat', per100: Macros(kcal: 114.33, prot: 4.43, fat: 1.13, carb: 20.7), portionG: 200, isDish: true),
            aMeal: MealSlot.lunch,
            aPortions: 1,
          ),
          child: const Text('open'),
        ),
      ),
    )));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.textContaining('229 kcal'), findsOneWidget);

    await aTester.tap(find.text('Grams'));
    await aTester.pumpAndSettle();
    final field = find.byKey(const ValueKey('nutrition.amount'));
    expect(aTester.widget<TextField>(field).controller!.text, '200');

    await aTester.enterText(field, '300');
    await aTester.pump();
    expect(find.textContaining('343 kcal'), findsOneWidget);

    await aTester.tap(find.text('Dinner'));
    await aTester.pump();
    await aTester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await aTester.pumpAndSettle();
    expect(result!.meal, MealSlot.dinner);
    expect(result!.grams, 300);
    expect(result!.portions, isNull);
  });

  testWidgets('day summary fits a narrow phone with and without a norm', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));

    await aTester.pumpWidget(_localized(ListView(
      padding: const EdgeInsets.all(16),
      children: [
        NutritionSummary(day: NutritionDay.fromJson(_dayJson())),
        const SizedBox(height: 16),
        NutritionSummary(day: NutritionDay.fromJson(_dayJson(aHasNorm: false))),
      ],
    )));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(4));
    expect(find.text('1,008 kcal left'), findsOneWidget);
    expect(find.text('To calculate your norm, add to your profile: weight, sex'), findsOneWidget);
    expect(find.textContaining('Workouts today: 350 kcal'), findsNWidgets(2));
  });

  testWidgets('new dish editor fits a narrow phone', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));

    await aTester.pumpWidget(_localized(const DishEditorScreen()));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.byKey(const ValueKey('dish.cooked')), findsOneWidget);
    await aTester.tap(find.text('Count'));
    await aTester.pumpAndSettle();
    expect(find.byKey(const ValueKey('dish.servings')), findsOneWidget);
    expect(aTester.takeException(), isNull);
  });
}
