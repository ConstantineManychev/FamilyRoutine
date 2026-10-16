import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/planner/planner_common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(320, 640);

Map<String, dynamic> _occurrenceJson({String aTiming = 'fixed', String aState = 'planned', String? aProgramId}) => {
      'event_id': 'e1',
      'occ_date': '2026-10-16',
      'date': '2026-10-16',
      'title': 'Очень длинное название события, которое не помещается в одну строку на узком экране',
      'note': null,
      'category': 'gym',
      'timing': aTiming,
      'start_ts': '2026-10-16T09:00:00Z',
      'end_ts': '2026-10-16T15:00:00Z',
      'duration_min': 40,
      'tz': 'Europe/Kyiv',
      'repeat': 'weekly',
      'state': aState,
      'is_moved': true,
      'program_id': aProgramId,
      'day_name': 'Ноги',
      'session_id': null,
      'is_session_active': false,
      'conflicts': [
        {'event_id': 'e2', 'occ_date': '2026-10-16', 'title': 'Встреча'},
        {'event_id': 'e2', 'occ_date': '2026-10-16', 'title': 'Встреча'},
      ],
      'overload': {'window_min': 360, 'busy_min': 420},
    };

class _KeyLoader extends AssetLoader
{
  const _KeyLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async => const {};
}

Widget _localized(Widget aChild)
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
          home: Scaffold(body: aChild),
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

  group('planner models', ()
  {
    test('occurrences parse dates, states and issues', ()
    {
      final item = Occurrence.fromJson(_occurrenceJson(aTiming: 'window', aProgramId: 'p1'));
      expect(item.occDate, DateTime(2026, 10, 16));
      expect(item.startTs.isUtc, isFalse);
      expect(item.timing, PlanTiming.window);
      expect(item.repeat, PlanRepeat.weekly);
      expect(item.isTraining, isTrue);
      expect(item.hasIssue, isTrue);
      expect(item.key, 'e1:2026-10-16');
    });

    test('only planned occurrences report issues', ()
    {
      expect(Occurrence.fromJson(_occurrenceJson(aState: 'skipped')).hasIssue, isFalse);
      expect(Occurrence.fromJson(_occurrenceJson(aState: 'done')).hasIssue, isFalse);
    });

    test('event payload keeps window only for window timing and wires dates', ()
    {
      final fixed = PlanEvent.payload(
        aTitle: 'Йога',
        aTiming: PlanTiming.fixed,
        aStartDate: DateTime(2026, 3, 9),
        aStartTime: const ClockTime(7, 5),
        aWindowMin: 120,
        aDurationMin: 45,
        aTz: 'Europe/Kyiv',
      );
      expect(fixed.containsKey('window_min'), isFalse);
      expect(fixed['start_date'], '2026-03-09');
      expect(fixed['start_time'], '07:05:00');

      final window = PlanEvent.payload(
        aTitle: 'Магазин',
        aTiming: PlanTiming.window,
        aStartDate: DateTime(2026, 3, 9),
        aStartTime: const ClockTime(12, 0),
        aWindowMin: 360,
        aDurationMin: 40,
        aTz: 'Europe/Kyiv',
        aRepeat: PlanRepeat.weekly,
        aWeekdayMask: 0x15,
        aUntilDate: DateTime(2026, 12, 31),
      );
      expect(window['window_min'], 360);
      expect(window['weekday_mask'], 0x15);
      expect(window['until_date'], '2026-12-31');
    });

    test('clock time wraps past midnight', ()
    {
      expect(const ClockTime(23, 30).plusMinutes(45).label, '00:15');
      expect(ClockTime.parse('18:05:00').totalMinutes, 18 * 60 + 5);
    });
  });

  testWidgets('occurrence tile fits a narrow phone with conflicts and a training button', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));
    final item = Occurrence.fromJson(_occurrenceJson(aProgramId: 'p1'));
    var isStarted = false;

    await aTester.pumpWidget(_localized(ListView(
      children: [
        OccurrenceTile(
          occurrence: item,
          isNow: true,
          isToday: true,
          onTap: () {},
          onDoneChanged: (_) {},
          onStartTraining: () => isStarted = true,
        ),
      ],
    )));
    await aTester.pumpAndSettle();

    expect(aTester.takeException(), isNull);
    expect(find.text('planner.start_training'), findsOneWidget);
    expect(find.text('planner.conflict'), findsOneWidget);
    expect(find.text('planner.overload'), findsOneWidget);
    await aTester.tap(find.text('planner.start_training'));
    expect(isStarted, isTrue);
  });

  testWidgets('regular occurrence toggles done through its checkbox', (aTester) async
  {
    await aTester.binding.setSurfaceSize(_narrowPhone);
    addTearDown(() => aTester.binding.setSurfaceSize(null));
    final item = Occurrence.fromJson(_occurrenceJson());
    bool? doneValue;

    await aTester.pumpWidget(_localized(OccurrenceTile(
      occurrence: item,
      isNow: false,
      isToday: true,
      onTap: () {},
      onDoneChanged: (aValue) => doneValue = aValue,
      onStartTraining: () {},
    )));
    await aTester.pumpAndSettle();

    expect(aTester.takeException(), isNull);
    expect(find.text('planner.start_training'), findsNothing);
    await aTester.tap(find.byType(Checkbox));
    expect(doneValue, isTrue);
  });
}
