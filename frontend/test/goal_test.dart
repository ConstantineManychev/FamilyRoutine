import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/nutrition/goal_screen.dart';
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

Map<String, dynamic> _macros(String aKcal, String aProt, String aFat, String aCarb) =>
    {'kcal': aKcal, 'prot': aProt, 'fat': aFat, 'carb': aCarb};

Map<String, dynamic> _norm(String aKind, String aMode, {String aKcal = '2759', String aDelta = '0', List<String> aWarnings = const []}) => {
      'target': _macros(aKcal, '128', '77', '389'),
      'kind': aKind,
      'mode': aMode,
      'age': aKind == 'child' ? 12 : 30,
      'maintenance_kcal': '2759',
      'bmr': aKind == 'child' ? null : '1780',
      'floor_kcal': aKind == 'child' ? null : '1780',
      'delta_kcal': aDelta,
      'pace_kg': null,
      'effective_pace_kg': aMode == 'maintain' ? null : '0.5',
      'target_kg': null,
      'weeks_to_target': null,
      'activity': 'moderate',
      'weight_kg': '80',
      'recent_workouts': 3,
      'is_training_boost': aKind == 'child',
      'warnings': aWarnings,
    };

NutritionGoal _goal({bool aIsChild = false, String aMode = 'maintain', Map<String, dynamic>? aNorm}) => NutritionGoal.fromJson({
      'mode': aMode,
      'pace_kg': null,
      'target_kg': null,
      'is_custom': false,
      'custom': null,
      'is_child': aIsChild,
      'norm': aNorm ?? _norm(aIsChild ? 'child' : 'adult', aMode),
      'norm_gaps': const [],
    });

class _FakeApi extends ApiSvc
{
  final bool isChild;
  final List<Map<String, dynamic>> previews = [];
  final List<Map<String, dynamic>> saved = [];

  _FakeApi({this.isChild = false}) : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<NutritionGoal> getNutritionGoal({String? aPersonId}) async => _goal(aIsChild: isChild);

  @override
  Future<NutritionGoal> previewNutritionGoal(GoalDraft aDraft, {String? aPersonId}) async
  {
    final json = aDraft.toJson();
    previews.add(json);
    final mode = json['mode'] as String;
    return _goal(
      aMode: mode,
      aNorm: _norm(
        json['is_custom'] == true ? 'custom' : 'adult',
        mode,
        aKcal: mode == 'lose' ? '2069' : '2759',
        aDelta: mode == 'lose' ? '-690' : '0',
        aWarnings: mode == 'lose' ? const ['deficit_capped'] : const [],
      ),
    );
  }

  @override
  Future<NutritionGoal> saveNutritionGoal(GoalDraft aDraft, {String? aPersonId}) async
  {
    saved.add(aDraft.toJson());
    return _goal(aMode: aDraft.mode.name);
  }
}

Widget _app(_FakeApi aApi)
{
  final router = GoRouter(
    initialLocation: '/app/goal',
    routes: [
      GoRoute(
        path: '/app',
        builder: (_, __) => const Scaffold(body: Text('home')),
        routes: [GoRoute(path: 'goal', builder: (_, __) => const GoalScreen())],
      ),
    ],
  );
  return ProviderScope(
    overrides: [apiProv.overrideWithValue(aApi)],
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'unused',
      assetLoader: const _EnglishLoader(),
      child: Builder(
        builder: (aContext) => MaterialApp.router(
          locale: aContext.locale,
          localizationsDelegates: aContext.localizationDelegates,
          supportedLocales: aContext.supportedLocales,
          theme: lightTheme,
          routerConfig: router,
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester aTester, _FakeApi aApi, {Size aSize = const Size(800, 1200)}) async
{
  aTester.view.physicalSize = aSize;
  aTester.view.devicePixelRatio = 1;
  addTearDown(aTester.view.reset);
  await aTester.pumpWidget(_app(aApi));
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

  test('custom macros convert percents and reject impossible input', ()
  {
    final grams = customFromInputs(aKcal: 2000, aProt: 150, aFat: 70, aCarb: 200, aIsPercent: false)!;
    expect(grams.prot, 150);
    final percent = customFromInputs(aKcal: 2000, aProt: 30, aFat: 30, aCarb: 40, aIsPercent: true)!;
    expect([percent.prot, percent.fat, percent.carb], [150, 67, 200]);
    expect(customFromInputs(aKcal: 2000, aProt: 30, aFat: 30, aCarb: 30, aIsPercent: true), isNull);
    expect(customFromInputs(aKcal: 500, aProt: 30, aFat: 30, aCarb: 40, aIsPercent: true), isNull);
    expect(customFromInputs(aKcal: 2000, aProt: 700, aFat: 30, aCarb: 40, aIsPercent: false), isNull);
    final shares = macroPercents(const Macros(kcal: 2000, prot: 150, fat: 67, carb: 200));
    expect(shares[0], closeTo(30, 0.01));
    expect(shares[1], closeTo(30.15, 0.01));
  });

  test('goal drafts send pace and target only with a weight goal', ()
  {
    expect(const GoalDraft(paceKg: 0.5, targetKg: 70).toJson(), {'mode': 'maintain', 'is_custom': false});
    expect(
      const GoalDraft(mode: GoalMode.lose, paceKg: 0.5, targetKg: 70, isCustom: true, custom: Macros(kcal: 1800, prot: 120, fat: 60, carb: 195)).toJson(),
      {
        'mode': 'lose',
        'pace_kg': '0.5',
        'target_kg': '70.0',
        'is_custom': true,
        'custom': {'kcal': '1800', 'prot': '120', 'fat': '60', 'carb': '195'},
      },
    );
  });

  testWidgets('choosing weight loss previews the capped deficit and saves', (aTester) async
  {
    final api = _FakeApi();
    await _open(aTester, api);
    expect(find.text('Maintain'), findsWidgets);
    expect(find.byKey(const ValueKey('goal.result.kcal')), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('goal.mode.lose')));
    await aTester.pump(const Duration(milliseconds: 400));
    await aTester.pumpAndSettle();
    expect(api.previews.last['mode'], 'lose');
    expect(api.previews.last['pace_kg'], '0.5');
    expect(find.textContaining('pace lowered to a safe 0.5 kg/week'), findsWidgets);
    expect(find.text('Lose weight · −690 kcal/day (≈0.5 kg/week)'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('goal.pace.0.75')));
    await aTester.pump(const Duration(milliseconds: 400));
    await aTester.pumpAndSettle();
    expect(api.previews.last['pace_kg'], '0.75');

    await aTester.ensureVisible(find.byKey(const ValueKey('goal.save')));
    await aTester.tap(find.byKey(const ValueKey('goal.save')));
    await aTester.pumpAndSettle();
    expect(api.saved.single['mode'], 'lose');
    expect(api.saved.single['pace_kg'], '0.75');
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('manual norm accepts percents that add up to one hundred', (aTester) async
  {
    final api = _FakeApi();
    await _open(aTester, api);

    await aTester.tap(find.byKey(const ValueKey('goal.custom')));
    await aTester.pumpAndSettle();
    final kcal = find.byKey(const ValueKey('goal.custom.kcal'));
    expect(aTester.widget<TextField>(kcal).controller!.text, '2759');

    await aTester.tap(find.text('Percent'));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('goal.custom.prot')), '50');
    await aTester.pump();
    expect(find.text('Enter 800–6000 kcal; macro percentages must add up to 100'), findsOneWidget);
    expect(aTester.widget<ElevatedButton>(find.byKey(const ValueKey('goal.save'))).onPressed, isNull);

    await aTester.enterText(find.byKey(const ValueKey('goal.custom.prot')), '25');
    await aTester.enterText(find.byKey(const ValueKey('goal.custom.fat')), '30');
    await aTester.enterText(find.byKey(const ValueKey('goal.custom.carb')), '45');
    await aTester.pump(const Duration(milliseconds: 400));
    await aTester.pumpAndSettle();
    expect(api.previews.last['is_custom'], true);
    expect(api.previews.last['custom'], {'kcal': '2759', 'prot': '172', 'fat': '92', 'carb': '310'});
    expect(aTester.widget<ElevatedButton>(find.byKey(const ValueKey('goal.save'))).onPressed, isNotNull);
  });

  testWidgets('children see the age norm without goal controls', (aTester) async
  {
    final api = _FakeApi(isChild: true);
    await _open(aTester, api);
    expect(find.textContaining('Under 18 the norm is based on age'), findsOneWidget);
    expect(find.text('Age-based norm, age 12'), findsOneWidget);
    expect(find.textContaining('raised: 3 workouts this week'), findsOneWidget);
    expect(find.byKey(const ValueKey('goal.mode.lose')), findsNothing);
    expect(find.byKey(const ValueKey('goal.save')), findsNothing);
  });

  testWidgets('goal screen fits a narrow phone', (aTester) async
  {
    final api = _FakeApi();
    await _open(aTester, api, aSize: _narrowPhone);
    await aTester.tap(find.byKey(const ValueKey('goal.mode.gain')));
    await aTester.pump(const Duration(milliseconds: 400));
    await aTester.pumpAndSettle();
    await aTester.ensureVisible(find.byKey(const ValueKey('goal.custom')));
    await aTester.tap(find.byKey(const ValueKey('goal.custom')));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
  });
}
