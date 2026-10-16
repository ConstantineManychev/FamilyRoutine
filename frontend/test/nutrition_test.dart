import 'dart:convert';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/nutrition/amount_sheet.dart';
import 'package:family_routine/ui/nutrition/dish_editor_screen.dart';
import 'package:family_routine/ui/nutrition/meal_target.dart';
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

Map<String, dynamic> _mark(String aId, String aStart, String? aEnd) =>
    {'id': aId, 'status': 'meal', 'note': null, 'start_ts': aStart, 'end_ts': aEnd};

Map<String, dynamic> _norm({List<String> aWarnings = const []}) => {
      'target': _macros('1774', '96', '59', '255'),
      'kind': 'adult',
      'mode': 'lose',
      'age': 36,
      'maintenance_kcal': '2218',
      'bmr': '1290',
      'floor_kcal': '1290',
      'delta_kcal': '-444',
      'pace_kg': '0.5',
      'effective_pace_kg': '0.4',
      'target_kg': '55',
      'weeks_to_target': 13,
      'activity': 'light',
      'weight_kg': '60',
      'recent_workouts': 0,
      'is_training_boost': false,
      'warnings': aWarnings,
    };

Map<String, dynamic> _dayJson({bool aHasNorm = true}) => {
      'date': '2026-10-16',
      'total': _macros('765.7', '42.1', '30.5', '90'),
      'meals': [
        {
          'mark': _mark('b1', '2026-10-16T07:30:00', '2026-10-16T08:00:00'),
          'total': _macros('302.7', '14', '12.7', '0.8'),
          'entries': [
            {
              'id': 'm1',
              'date': '2026-10-16',
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
              'status_mark_id': 'b1',
              'created_ts': '2026-10-16T07:00:00Z',
            },
          ],
        },
        {
          'mark': _mark('b2', '2026-10-16T10:15:00', '2026-10-16T10:30:00'),
          'total': _macros('0', '0', '0', '0'),
          'entries': const [],
        },
      ],
      'unlinked': [
        {
          'id': 'm2',
          'date': '2026-10-16',
          'source': 'quick',
          'title': null,
          'grams': null,
          'portions': null,
          'portion_g': null,
          'is_ml': false,
          'per_100': null,
          'total': _macros('120', '0', '6', '0'),
          'status_mark_id': null,
          'created_ts': '2026-10-16T12:00:00Z',
        },
      ],
      'unlinked_total': _macros('120', '0', '6', '0'),
      'norm': aHasNorm ? _norm(aWarnings: const ['deficit_capped', 'unknown']) : null,
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

  test('nutrition day parses meal blocks, unlinked entries and the norm', ()
  {
    final day = NutritionDay.fromJson(_dayJson());
    expect(day.date, DateTime(2026, 10, 16));
    expect(day.total.kcal, 765.7);
    expect(day.meals.map((aMeal) => aMeal.kind), [MealKind.breakfast, MealKind.secondBreakfast]);
    expect(day.mealById('b1')!.entries.single.portions, 2);
    expect(day.mealById('b1')!.entries.single.per100!.kcal, 157);
    expect(day.mealById('b2')!.entries, isEmpty);
    expect(day.activeMeal(DateTime(2026, 10, 16, 10, 20))!.mark.id, 'b2');
    expect(day.activeMeal(DateTime(2026, 10, 16, 9)), isNull);
    expect(day.unlinked.single.source, MealSource.quick);
    expect(day.unlinkedTotal.kcal, 120);
    expect(day.norm!.target.prot, 96);
    expect(day.norm!.mode, GoalMode.lose);
    expect(day.norm!.deltaKcal, -444);
    expect(day.norm!.weeksToTarget, 13);
    expect(day.norm!.warnings, [NormWarning.deficitCapped]);
    expect(day.norm!.activity, ActivityLevel.light);
    expect(day.workoutKcal, 350);

    final gaps = NutritionDay.fromJson(_dayJson(aHasNorm: false));
    expect(gaps.norm, isNull);
    expect(gaps.normGaps, [NormGap.weight, NormGap.sex]);
  });

  test('meal names follow the time of the block', ()
  {
    MealKind at(int aHour, [int aMinute = 0]) => MealKind.forTime(DateTime(2026, 10, 16, aHour, aMinute));
    expect(at(3, 59), MealKind.nightSnack);
    expect(at(4), MealKind.breakfast);
    expect(at(8, 59), MealKind.breakfast);
    expect(at(9), MealKind.secondBreakfast);
    expect(at(12), MealKind.lunch);
    expect(at(15, 59), MealKind.lunch);
    expect(at(16), MealKind.afternoonSnack);
    expect(at(18), MealKind.dinner);
    expect(at(21, 59), MealKind.dinner);
    expect(at(22), MealKind.nightSnack);
  });

  test('default meal target prefers the requested or active block', ()
  {
    final day = NutritionDay.fromJson(_dayJson());
    final date = DateTime(2026, 10, 16);
    expect(defaultMealTarget(date, day.meals, aMarkId: 'b1', aNow: DateTime(2026, 10, 16, 20)).markId, 'b1');
    expect(defaultMealTarget(date, day.meals, aNow: DateTime(2026, 10, 16, 10, 20)).markId, 'b2');
    final fresh = defaultMealTarget(date, day.meals, aNow: DateTime(2026, 10, 16, 13, 5, 42));
    expect(fresh.isNew, isTrue);
    expect(fresh.start, DateTime(2026, 10, 16, 13, 5));
    expect(fresh.end, DateTime(2026, 10, 16, 13, 35));
    expect(fresh.kind, MealKind.lunch);
    expect(defaultMealTarget(date, day.meals, aNow: DateTime(2026, 10, 18, 9)).markId, 'b2');
    expect(defaultMealTarget(date, const [], aNow: DateTime(2026, 10, 18, 9)).start, DateTime(2026, 10, 16, 12));
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
    expect(const AmountResult(grams: 150).toJson(), {'grams': '150'});
    expect(const AmountResult(portions: 1.5).toJson(), {'portions': '1.5'});
    expect(amountText(0.25), '0.25');
    expect(amountText(2), '2');
    expect(parseAmountText('1,5'), 1.5);
  });

  testWidgets('amount sheet converts between grams and portions and returns the chosen meal block', (aTester) async
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
            aMealChoice: MealChoice(
              date: DateTime(2026, 10, 16),
              meals: NutritionDay.fromJson(_dayJson()).meals,
              initial: MealTarget.existing('b1', DateTime(2026, 10, 16, 7, 30)),
            ),
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

    await aTester.ensureVisible(find.byKey(const ValueKey('meal.target.b2')));
    await aTester.tap(find.byKey(const ValueKey('meal.target.b2')));
    await aTester.pump();
    await aTester.tap(find.widgetWithText(ElevatedButton, 'Add'));
    await aTester.pumpAndSettle();
    expect(result!.target!.markId, 'b2');
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
    expect(find.text('Lose weight · −444 kcal/day (≈0.4 kg/week)'), findsOneWidget);
    expect(find.textContaining('pace lowered to a safe 0.4 kg/week'), findsOneWidget);
    expect(find.textContaining('Maintenance 2,218 kcal: resting 1,290 kcal'), findsOneWidget);
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
