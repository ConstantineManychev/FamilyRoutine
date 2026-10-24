import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_icons.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/common/person_switcher.dart';
import 'package:family_routine/ui/energy/energy_chart_block.dart';
import 'package:family_routine/ui/nutrition/nutrition_today_block.dart';
import 'package:family_routine/ui/routine/family_timeline_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(360, 760);

const List<PersonRef> _people = [
  PersonRef(id: 'me', firstName: 'Anna', lastName: 'Test', isMe: true, canEdit: true),
  PersonRef(id: 'kid', firstName: 'Kid', lastName: 'Test', isManaged: true, canEdit: true),
  PersonRef(id: 'bob', firstName: 'Bob', lastName: 'Test'),
];

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _macros(String aKcal) => {'kcal': aKcal, 'prot': '0', 'fat': '0', 'carb': '0'};

class _FakeApi extends ApiSvc
{
  final List<String?> dayRequests = [];
  final List<int> energyDays = [];
  final List<(String?, DateTime, double)> energyMarks = [];
  final List<(RoutineStatus, DateTime?, DateTime?, String?)> createdMarks = [];
  final List<(String, PlanState)> savedOccurrences = [];
  int timelineLoads = 0;

  _FakeApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<List<PersonRef>> getPeople() async => _people;

  @override
  Future<List<FamDto>> getFams() async => const [];

  @override
  Future<NutritionDay> getNutritionDay(DateTime aDate, {String? aPersonId}) async
  {
    dayRequests.add(aPersonId);
    return NutritionDay.fromJson({
      'person_id': aPersonId ?? 'me',
      'can_edit': aPersonId != 'bob',
      'date': dateWire(aDate),
      'total': _macros(aPersonId == 'bob' ? '900' : '400'),
      'meals': const [],
      'unlinked': const [],
      'unlinked_total': _macros('0'),
      'norm': null,
      'norm_gaps': const [],
      'workout_kcal': '0',
    });
  }

  @override
  Future<EnergyMark> setEnergyMark({String? aPersonId, required DateTime aTs, required double aKcal}) async
  {
    energyMarks.add((aPersonId, aTs, aKcal));
    return EnergyMark(id: 'm1', ts: aTs, kcal: aKcal);
  }

  @override
  Future<StatusMarkDto> createMark(
    RoutineStatus aStatus,
    {
      String? aNote,
      DateTime? aStartTs,
      DateTime? aEndTs,
      String? aPersonId,
    }
  ) async
  {
    createdMarks.add((aStatus, aStartTs, aEndTs, aPersonId));
    return StatusMarkDto(id: 'new', status: aStatus, startTs: aStartTs ?? DateTime.now(), endTs: aEndTs);
  }

  @override
  Future<void> saveOccurrence(String aEventId, DateTime aOccDate, PlanState aState, {DateTime? aMovedStart}) async
  {
    savedOccurrences.add((aEventId, aState));
  }

  @override
  Future<OccurrenceDetails> getOccurrence(String aEventId, DateTime aOccDate) async
  {
    final today = DateTime.now();
    final lunch = DateTime(today.year, today.month, today.day, 13);
    final isDone = savedOccurrences.isNotEmpty;
    final start = lunch.toUtc().toIso8601String();
    final end = lunch.add(const Duration(minutes: 30)).toUtc().toIso8601String();
    return OccurrenceDetails.fromJson({
      'occurrence': {
        'event_id': 'lunch', 'occ_date': dateWire(lunch), 'date': dateWire(lunch), 'title': 'Lunch', 'category': 'meal',
        'timing': 'fixed', 'start_ts': start, 'end_ts': end, 'duration_min': 30, 'tz': 'UTC', 'repeat': 'daily',
        'state': isDone ? 'done' : 'planned', 'status_mark_id': isDone ? 'lunch-mark' : null,
      },
      'owner_id': 'kid',
      'is_custom': false,
      'content': {
        'foods': [
          {'id': 'soup', 'source': 'quick', 'title': 'Soup', 'is_ml': false, 'total': _macros('450')},
        ],
        'total': _macros('450'),
        'tasks': const [],
        'studies': const [],
      },
    });
  }

  @override
  Future<TimelineDto> getTimeline({String? aFamilyId, required DateTime aFrom, required DateTime aTo}) async
  {
    timelineLoads++;
    final today = DateTime.now();
    final lunch = DateTime(today.year, today.month, today.day, 13);
    final isAccepted = savedOccurrences.isNotEmpty;
    return TimelineDto.fromJson({
      'family_id': aFamilyId,
      'family_name': 'Home',
      'members': [
        {'user_id': 'me', 'first_name': 'Anna', 'last_name': 'Test', 'is_me': true, 'can_edit': true, 'marks': const []},
        {
          'user_id': 'kid', 'first_name': 'Kid', 'last_name': 'Test', 'is_me': false, 'is_managed': true, 'can_edit': true,
          'marks': [
            if (isAccepted)
              {
                'id': 'lunch-mark', 'status': 'meal', 'note': 'Lunch',
                'start_ts': lunch.toUtc().toIso8601String(),
                'end_ts': lunch.add(const Duration(minutes: 30)).toUtc().toIso8601String(),
              },
          ],
          'plans': [
            if (!isAccepted)
              {
                'event_id': 'lunch', 'occ_date': dateWire(lunch), 'date': dateWire(lunch), 'title': 'Lunch',
                'category': 'meal', 'timing': 'fixed', 'start_ts': lunch.toUtc().toIso8601String(),
                'end_ts': lunch.add(const Duration(minutes: 30)).toUtc().toIso8601String(), 'duration_min': 30,
                'tz': 'UTC', 'repeat': 'daily', 'state': 'planned',
              },
          ],
        },
        {'user_id': 'bob', 'first_name': 'Bob', 'last_name': 'Test', 'is_me': false, 'can_edit': false, 'marks': const []},
      ],
    });
  }

  @override
  Future<EnergyDay> getEnergyDay(DateTime aDate, {int aDays = 1}) async
  {
    energyDays.add(aDays);
    final start = DateTime.utc(2026, 10, 16, 21);
    String at(int aHours) => start.add(Duration(hours: aHours)).toIso8601String();
    return EnergyDay.fromJson({
      'date': dateWire(aDate),
      'day_start': start.toIso8601String(),
      'day_end': at(24),
      'people': [
        {
          'person_id': 'me', 'first_name': 'Anna', 'last_name': 'Test', 'is_me': true, 'is_managed': false,
          'can_edit': true, 'daily_burn': '2400', 'eaten': 600, 'burned_base': 1200, 'burned_workouts': 300,
          'balance': -900,
          'points': [
            {'ts': at(0), 'kcal': 0}, {'ts': at(8), 'kcal': -800}, {'ts': at(8), 'kcal': -200},
            {'ts': at(10), 'kcal': -700}, {'ts': at(12), 'kcal': -900},
          ],
        },
        {
          'person_id': 'kid', 'first_name': 'Kid', 'last_name': 'Test', 'is_me': false, 'is_managed': true,
          'can_edit': true, 'daily_burn': null, 'eaten': 300, 'burned_base': 0, 'burned_workouts': 0, 'balance': 300,
          'points': [
            {'ts': at(0), 'kcal': 0}, {'ts': at(9), 'kcal': 0}, {'ts': at(9), 'kcal': 300}, {'ts': at(12), 'kcal': 300},
          ],
        },
      ],
    });
  }
}

Widget _app(Widget aChild, {ApiSvc? aApi})
{
  return ProviderScope(
    overrides: [
      if (aApi != null) apiProv.overrideWithValue(aApi),
      sessionUserIdProv.overrideWithValue('me'),
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
          home: Scaffold(body: SingleChildScrollView(child: aChild)),
        ),
      ),
    ),
  );
}

void main()
{
  setUpAll(()
  {
    SharedPreferences.setMockInitialValues({});
  });

  test('energy at a moment follows jumps and stops at the last point', ()
  {
    final start = DateTime.utc(2026, 10, 17);
    final points = [
      EnergyPoint(start, 0),
      EnergyPoint(start.add(const Duration(hours: 8)), -800),
      EnergyPoint(start.add(const Duration(hours: 8)), -200),
      EnergyPoint(start.add(const Duration(hours: 10)), -400),
    ];
    expect(energyAt(points, start.add(const Duration(hours: 4))), -400);
    expect(energyAt(points, start.add(const Duration(hours: 8))), -200);
    expect(energyAt(points, start.add(const Duration(hours: 9))), -300);
    expect(energyAt(points, start.add(const Duration(hours: 11))), isNull);
    expect(energyAt(const [], start), isNull);
  });

  testWidgets('person strip flips between people by arrows and swipes', (aTester) async
  {
    await EasyLocalization.ensureInitialized();
    await aTester.binding.setSurfaceSize(_narrowPhone);
    var index = 0;
    await aTester.pumpWidget(_app(StatefulBuilder(
      builder: (aContext, aSetState) => PersonSwipe(
        people: _people,
        index: index,
        onChanged: (aIndex) => aSetState(() => index = aIndex),
        child: SizedBox(height: 200, child: Center(child: Text('page ${_people[index].id}'))),
      ),
    )));
    await aTester.pumpAndSettle();

    expect(find.text('Me'), findsOneWidget);
    expect(find.text('page me'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('person.next')));
    await aTester.pumpAndSettle();
    expect(find.text('Kid Test'), findsOneWidget);
    expect(find.text('child'), findsOneWidget);

    await aTester.fling(find.text('page kid'), const Offset(-300, 0), 1200);
    await aTester.pumpAndSettle();
    expect(index, 2);
    expect(find.text('Bob Test'), findsOneWidget);
    expect(find.byIcon(AppIcons.eye), findsOneWidget);

    await aTester.fling(find.text('page bob'), const Offset(300, 0), 1200);
    await aTester.pumpAndSettle();
    expect(index, 1);
    await aTester.binding.setSurfaceSize(null);
  });

  testWidgets('nutrition block offers adding only for people the viewer can edit', (aTester) async
  {
    await EasyLocalization.ensureInitialized();
    await aTester.binding.setSurfaceSize(_narrowPhone);
    final api = _FakeApi();
    await aTester.pumpWidget(_app(const NutritionTodayBlock(), aApi: api));
    await aTester.pumpAndSettle();

    final addButton = find.byTooltip('Add food');
    expect(addButton, findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('person.next')));
    await aTester.pumpAndSettle();
    expect(api.dayRequests, [null, 'kid']);
    expect(addButton, findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('person.next')));
    await aTester.pumpAndSettle();
    expect(api.dayRequests.last, 'bob');
    expect(find.text('Bob Test'), findsOneWidget);
    expect(addButton, findsNothing);
    expect(aTester.takeException(), isNull);
    await aTester.binding.setSurfaceSize(null);
  });

  testWidgets('energy chart draws a line per person with a legend that hides lines', (aTester) async
  {
    await EasyLocalization.ensureInitialized();
    await aTester.binding.setSurfaceSize(_narrowPhone);
    final api = _FakeApi();
    await aTester.pumpWidget(_app(const EnergyChartBlock(), aApi: api));
    await aTester.pumpAndSettle();

    expect(find.text('Calorie balance'), findsOneWidget);
    expect(find.byKey(const ValueKey('energy.chart')), findsOneWidget);
    expect(find.byKey(const ValueKey('energy.legend.me')), findsOneWidget);
    expect(find.byKey(const ValueKey('energy.legend.kid')), findsOneWidget);
    expect(find.textContaining('no norm'), findsOneWidget);
    expect(find.textContaining('workouts 300'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('energy.legend.kid')));
    await aTester.pumpAndSettle();
    final hidden = aTester.widget<Opacity>(
      find.ancestor(of: find.byKey(const ValueKey('energy.legend.kid')), matching: find.byType(Opacity)).first,
    );
    expect(hidden.opacity, lessThan(1));

    await aTester.tapAt(aTester.getCenter(find.byKey(const ValueKey('energy.chart'))));
    await aTester.pumpAndSettle();
    expect(find.text('Calories at this time'), findsOneWidget);
    final field = aTester.widget<TextField>(find.byKey(const ValueKey('energy.correct.kcal')));
    expect(int.parse(field.controller!.text), inInclusiveRange(-900, -700));
    await aTester.enterText(find.byKey(const ValueKey('energy.correct.kcal')), '250');
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('energy.correct.save')));
    await aTester.pumpAndSettle();
    expect(api.energyMarks.single.$1, isNull);
    expect(api.energyMarks.single.$3, 250);

    await aTester.tap(find.byKey(const ValueKey('energy.range.days.7')));
    await aTester.pumpAndSettle();
    expect(api.energyDays.last, 7);
    expect(find.byKey(const ValueKey('energy.scroll')), findsOneWidget);
    expect(aTester.takeException(), isNull);
    await aTester.binding.setSurfaceSize(null);
  });

  testWidgets('tapping an empty spot on a child row creates a block for the child', (aTester) async
  {
    await EasyLocalization.ensureInitialized();
    await aTester.binding.setSurfaceSize(const Size(900, 900));
    final api = _FakeApi();
    await aTester.pumpWidget(_app(const FamilyTimelineCard(familyId: 'f1', title: 'Home'), aApi: api));
    await aTester.pumpAndSettle();

    expect(find.byKey(const ValueKey('timeline.track.bob')), findsNothing);
    final track = find.byKey(const ValueKey('timeline.track.kid'));
    expect(track, findsOneWidget);
    await aTester.tapAt(aTester.getTopLeft(track) + const Offset(20, 10));
    await aTester.pumpAndSettle();
    expect(find.text('New block: Kid Test'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('block.status.school')));
    await aTester.tap(find.byKey(const ValueKey('block.minutes.30')));
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('block.save')));
    await aTester.pumpAndSettle();
    final created = api.createdMarks.single;
    expect(created.$1, RoutineStatus.school);
    expect(created.$4, 'kid');
    expect(created.$3!.difference(created.$2!), const Duration(minutes: 30));

    await aTester.tap(find.byKey(const ValueKey('timeline.range.days.14')));
    await aTester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline.scroll')), findsOneWidget);
    expect(aTester.takeException(), isNull);
    await aTester.binding.setSurfaceSize(null);
  });

  testWidgets('a plan shows its content and becomes a block once it is done', (aTester) async
  {
    await EasyLocalization.ensureInitialized();
    await aTester.binding.setSurfaceSize(const Size(900, 1200));
    final api = _FakeApi();
    await aTester.pumpWidget(_app(const FamilyTimelineCard(familyId: 'f1', title: 'Home'), aApi: api));
    await aTester.pumpAndSettle();

    final today = DateTime.now();
    final plan = find.byKey(ValueKey('timeline.plan.lunch:${dateWire(today)}'));
    expect(plan, findsOneWidget);
    expect(find.textContaining('Translucent blocks are plans.'), findsOneWidget);
    await aTester.tap(plan);
    await aTester.pumpAndSettle();

    expect(find.text('Soup'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan.total')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan.edit_day')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan.edit_series')), findsOneWidget);
    expect(find.textContaining('the food goes to the diary'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('plan.done')));
    await aTester.pumpAndSettle();
    expect(api.savedOccurrences.single, ('lunch', PlanState.done));
    expect(find.byKey(const ValueKey('plan.undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan.open_block')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan.edit_day')), findsNothing);

    await aTester.tapAt(const Offset(10, 10));
    await aTester.pumpAndSettle();
    expect(api.timelineLoads, greaterThan(1));
    expect(plan, findsNothing);
    expect(find.bySemanticsLabel(RegExp('Kid Test — Meal')), findsOneWidget);
    expect(aTester.takeException(), isNull);
    await aTester.binding.setSurfaceSize(null);
  });
}
