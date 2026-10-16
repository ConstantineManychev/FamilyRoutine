import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/training/exercise_progress_screen.dart';
import 'package:family_routine/ui/training/training_format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(320, 640);

class _KeyLoader extends AssetLoader
{
  const _KeyLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async => const {};
}

Widget _localized(Widget Function(BuildContext aContext) aBuild)
{
  return ProviderScope(
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'unused',
      assetLoader: const _KeyLoader(),
      child: Builder(
        builder: (aContext) => MaterialApp(
          locale: aContext.locale,
          localizationsDelegates: aContext.localizationDelegates,
          supportedLocales: aContext.supportedLocales,
          theme: lightTheme,
          home: Scaffold(body: Builder(builder: aBuild)),
        ),
      ),
    ),
  );
}

ProgressPoint _point(int aDay, double aWeight, int aReps, double aE1rm) => ProgressPoint(
      sessionId: 's$aDay',
      startedTs: DateTime(2026, 9, aDay, 18),
      e1rmKg: aE1rm,
      topWeightKg: aWeight,
      topReps: aReps,
      totalReps: aReps * 3,
      volumeKg: aWeight * aReps * 3,
    );

void main()
{
  setUpAll(() async
  {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableBuildModes = [];
    await EasyLocalization.ensureInitialized();
  });

  test('session exercises read the progression advice', ()
  {
    final exercise = SessionExercise.fromJson({
      'ex_id': 'e1',
      'ex_code': 'bench_press',
      'ex_name': 'Bench press',
      'ex_type': 'strength',
      'sets': const [],
      'advice': {'kind': 'increase_weight', 'from': '60.00', 'to': '62.50'},
    });
    expect(exercise.advice!.kind, ProgressionKind.increaseWeight);
    expect(exercise.advice!.to, 62.5);
    expect(ProgressionAdvice.fromJson({'kind': 'unknown'}), isNull);
    expect(ProgressionAdvice.fromJson(null), isNull);
  });

  test('progress points pick the value of the measure', ()
  {
    final progress = ExerciseProgress.fromJson({
      'ex_id': 'e1',
      'ex_code': null,
      'ex_name': 'Plank',
      'measure': 'duration',
      'points': [
        {'session_id': 's1', 'started_ts': '2026-09-01T18:00:00Z', 'best_duration_sec': 70, 'total_reps': 0, 'volume_kg': '0'},
      ],
    });
    expect(progress.measure, ProgressMeasure.duration);
    expect(progress.points.single.valueOf(ProgressMeasure.duration), 70);
    expect(_point(1, 60, 10, 80).valueOf(ProgressMeasure.weight), 80);
    expect(ProgressPoint(sessionId: 's', startedTs: DateTime(2026), topWeightKg: 50).valueOf(ProgressMeasure.weight), 50);
  });

  test('chart ticks are clean numbers around the data', ()
  {
    expect(niceTicks(56, 82), [50, 60, 70, 80, 90]);
    expect(niceTicks(60, 60), [56, 58, 60, 62, 64]);
    expect(niceTicks(1.5, 3.2).first, lessThanOrEqualTo(1.5));
  });

  testWidgets('advice wording follows the kind', (aTester) async
  {
    final texts = <String>[];
    await aTester.pumpWidget(_localized((aContext)
    {
      texts
        ..clear()
        ..addAll([
          adviceText(aContext, const ProgressionAdvice(kind: ProgressionKind.increaseWeight, from: 60, to: 62.5)),
          adviceText(aContext, const ProgressionAdvice(kind: ProgressionKind.addReps, from: 60, to: 60)),
          adviceText(aContext, const ProgressionAdvice(kind: ProgressionKind.addReps)),
          adviceText(aContext, const ProgressionAdvice(kind: ProgressionKind.deload, from: 62.5, to: 56)),
          adviceText(aContext, const ProgressionAdvice(kind: ProgressionKind.addTime, from: 60, to: 70)),
        ]);
      return const SizedBox();
    }));
    await aTester.pumpAndSettle();
    expect(texts, [
      'training.advice_increase',
      'training.advice_reps',
      'training.advice_reps_body',
      'training.advice_deload',
      'training.advice_time',
    ]);
  });

  testWidgets('progress chart fits a narrow phone and taps select the nearest workout', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));
    final points = [_point(1, 60, 10, 80), _point(4, 62.5, 8, 79.2), _point(8, 62.5, 10, 83.3)];

    await aTester.pumpWidget(_localized((_) => ListView(
          padding: const EdgeInsets.all(16),
          children: [ProgressChart(measure: ProgressMeasure.weight, points: points)],
        )));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.textContaining('83.3'), findsOneWidget);

    final chart = aTester.getRect(find.byType(CustomPaint).last);
    await aTester.tapAt(Offset(chart.left + 70, chart.center.dy));
    await aTester.pump();
    expect(find.textContaining('80'), findsWidgets);
    expect(find.textContaining('83.3'), findsNothing);
  });
}

