import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/routine/mark_sheet.dart';
import 'package:family_routine/ui/routine/status_sheet.dart';
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

class _MarkUpdate
{
  final RoutineStatus status;
  final String? note;
  final DateTime? startTs;
  final DateTime? endTs;
  final bool isOpenEnd;

  const _MarkUpdate(this.status, this.note, this.startTs, this.endTs, this.isOpenEnd);
}

class _FakeApi extends ApiSvc
{
  final Map<String, dynamic> details;
  final StatusMarkDto? current;
  final List<_MarkUpdate> updates = [];
  final List<RoutineStatus> created = [];
  final List<DateTime?> createdStarts = [];

  _FakeApi(this.details, {this.current}) : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<MarkDetails> getMarkDetails(String aId) async => MarkDetails.fromJson(details);

  @override
  Future<StatusMarkDto?> getCurrentMark() async => current;

  @override
  Future<StatusMarkDto> createMark(RoutineStatus aStatus, {String? aNote, DateTime? aStartTs}) async
  {
    created.add(aStatus);
    createdStarts.add(aStartTs);
    return StatusMarkDto(id: 'new', status: aStatus, startTs: aStartTs ?? DateTime.now());
  }

  @override
  Future<StatusMarkDto> updateMark(
    String aId,
    RoutineStatus aStatus,
    String? aNote,
    {
      DateTime? aStartTs,
      DateTime? aEndTs,
      bool aIsOpenEnd = false,
    }
  ) async
  {
    updates.add(_MarkUpdate(aStatus, aNote, aStartTs, aEndTs, aIsOpenEnd));
    return StatusMarkDto(id: aId, status: aStatus, startTs: aStartTs ?? DateTime.now());
  }
}

Map<String, dynamic> _macros(String aKcal, String aProt, String aFat, String aCarb) =>
    {'kcal': aKcal, 'prot': aProt, 'fat': aFat, 'carb': aCarb};

Map<String, dynamic> _mark(String aStatus, {String aStart = '2026-10-16T09:15:00', String? aEnd = '2026-10-16T10:00:00'}) => {
      'id': 'mk1',
      'status': aStatus,
      'note': null,
      'start_ts': aStart,
      'end_ts': aEnd,
    };

Map<String, dynamic> _mealDetails({bool aIsMine = true}) => {
      'mark': _mark('meal'),
      'owner_id': 'u1',
      'owner_name': 'Alice Smith',
      'is_mine': aIsMine,
      'is_details_hidden': false,
      'workout': null,
      'meals': {
        'total': _macros('403', '13', '1', '68'),
        'entries': [
          {
            'id': 'e1',
            'date': '2026-10-16',
            'meal': 'breakfast',
            'source': 'item',
            'item_id': 'i1',
            'title': 'Buckwheat',
            'grams': '100',
            'is_ml': false,
            'per_100': _macros('343', '13', '1', '68'),
            'total': _macros('343', '13', '1', '68'),
            'status_mark_id': 'mk1',
          },
          {
            'id': 'e2',
            'date': '2026-10-16',
            'meal': 'breakfast',
            'source': 'quick',
            'title': 'Coffee',
            'grams': null,
            'is_ml': false,
            'per_100': null,
            'total': _macros('60', '0', '0', '0'),
            'status_mark_id': 'mk1',
          },
        ],
      },
    };

Map<String, dynamic> _gymDetails({bool aIsHidden = false}) => {
      'mark': _mark('gym'),
      'owner_id': 'u2',
      'owner_name': 'Bob Stone',
      'is_mine': false,
      'is_details_hidden': aIsHidden,
      'meals': null,
      'workout': aIsHidden
          ? null
          : {
              'id': 's1',
              'program_name': 'Split',
              'day_name': 'Chest day',
              'started_ts': '2026-10-16T09:20:00',
              'finished_ts': '2026-10-16T09:55:00',
              'intensity': null,
              'kcal': null,
              'note': null,
              'exercises': [
                {
                  'ex_id': 'x1',
                  'ex_code': 'bench_press',
                  'ex_name': 'Bench press',
                  'ex_type': 'strength',
                  'sets': [
                    {'set_no': 1, 'reps': 10, 'weight_kg': '50', 'is_done': true},
                    {'set_no': 2, 'reps': 8, 'weight_kg': '55', 'is_done': true},
                  ],
                },
              ],
            },
    };

Widget _app(Widget aChild, _FakeApi aApi)
{
  return ProviderScope(
    overrides: [
      apiProv.overrideWithValue(aApi),
      sessionUserIdProv.overrideWithValue('u1'),
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
          home: Scaffold(body: aChild),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester aTester, _FakeApi aApi, {Size aSize = const Size(800, 1000)}) async
{
  aTester.view.physicalSize = aSize;
  aTester.view.devicePixelRatio = 1;
  addTearDown(aTester.view.reset);
  await aTester.pumpWidget(_app(
    Builder(
      builder: (aContext) => TextButton(onPressed: () => openMarkSheet(aContext, 'mk1'), child: const Text('open')),
    ),
    aApi,
  ));
  await aTester.pumpAndSettle();
  await aTester.tap(find.text('open'));
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

  test('mark details parse the workout and linked meals', ()
  {
    final meal = MarkDetails.fromJson(_mealDetails());
    expect(meal.isMine, isTrue);
    expect(meal.mark.status, RoutineStatus.meal);
    expect(meal.meals!.total.kcal, 403);
    expect(meal.meals!.entries.map((aEntry) => aEntry.statusMarkId), ['mk1', 'mk1']);
    expect(meal.workout, isNull);

    final gym = MarkDetails.fromJson(_gymDetails());
    expect(gym.ownerName, 'Bob Stone');
    expect(gym.workout!.exercises.single.sets.length, 2);

    final hidden = MarkDetails.fromJson(_gymDetails(aIsHidden: true));
    expect(hidden.isDetailsHidden, isTrue);
    expect(hidden.workout, isNull);
  });

  testWidgets('own meal block lists food and saves a new type without touching times', (aTester) async
  {
    final api = _FakeApi(_mealDetails());
    await _openSheet(aTester, api);

    expect(find.text('Buckwheat'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.byKey(const ValueKey('mark.meals_total')), findsOneWidget);
    expect(find.byKey(const ValueKey('mark.add_food')), findsOneWidget);
    expect(find.byKey(const ValueKey('mark.link_meals')), findsOneWidget);

    final save = find.byKey(const ValueKey('mark.save'));
    expect(aTester.widget<ElevatedButton>(save).onPressed, isNull);

    await aTester.tap(find.byKey(const ValueKey('mark.type.leisure')));
    await aTester.pumpAndSettle();
    expect(find.text('Diary entries stay in the food diary but are unlinked from this block.'), findsOneWidget);
    expect(aTester.widget<ElevatedButton>(save).onPressed, isNotNull);

    await aTester.tap(save);
    await aTester.pumpAndSettle();
    expect(api.updates.single.status, RoutineStatus.leisure);
    expect(api.updates.single.startTs, isNull);
    expect(api.updates.single.endTs, isNull);
    expect(api.updates.single.isOpenEnd, isFalse);
    expect(find.text('Buckwheat'), findsNothing);
  });

  testWidgets('making an own block open-ended sends the open end flag', (aTester) async
  {
    final api = _FakeApi(_mealDetails());
    await _openSheet(aTester, api);

    await aTester.tap(find.byKey(const ValueKey('mark.open_end')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('mark.save')));
    await aTester.pumpAndSettle();

    final update = api.updates.single;
    expect(update.status, RoutineStatus.meal);
    expect(update.startTs, DateTime.parse('2026-10-16T09:15:00'));
    expect(update.endTs, isNull);
    expect(update.isOpenEnd, isTrue);
  });

  testWidgets('member blocks are read-only and show the shared workout', (aTester) async
  {
    final api = _FakeApi(_gymDetails());
    await _openSheet(aTester, api);

    expect(find.textContaining('Bob Stone'), findsOneWidget);
    expect(find.text('Chest day'), findsOneWidget);
    expect(find.text('Bench press'), findsOneWidget);
    expect(find.text('50×10, 55×8'), findsOneWidget);
    expect(find.byKey(const ValueKey('mark.open_workout')), findsOneWidget);
    expect(find.byKey(const ValueKey('mark.save')), findsNothing);
    expect(find.byKey(const ValueKey('mark.delete')), findsNothing);
    expect(find.byKey(const ValueKey('mark.type.work')), findsNothing);
  });

  testWidgets('hidden member details explain why nothing is shown', (aTester) async
  {
    final api = _FakeApi(_gymDetails(aIsHidden: true));
    await _openSheet(aTester, api);

    expect(find.text('This member does not share workouts with this group.'), findsOneWidget);
    expect(find.text('Bench press'), findsNothing);
  });

  testWidgets('own block sheet fits a narrow phone', (aTester) async
  {
    final api = _FakeApi(_mealDetails());
    await _openSheet(aTester, api, aSize: _narrowPhone);

    expect(aTester.takeException(), isNull);
    expect(find.byKey(const ValueKey('mark.save')).hitTestable(), findsOneWidget);
  });

  testWidgets('header line shows the current status and starts a new one earlier', (aTester) async
  {
    final api = _FakeApi(
      _mealDetails(),
      current: StatusMarkDto(id: 'c1', status: RoutineStatus.work, startTs: DateTime(2026, 10, 16, 9, 15)),
    );
    aTester.view.physicalSize = _narrowPhone;
    aTester.view.devicePixelRatio = 1;
    addTearDown(aTester.view.reset);
    await aTester.pumpWidget(_app(
      const Row(
        children: [
          StatusAvatar(initials: 'AS'),
          Expanded(child: StatusLine()),
        ],
      ),
      api,
    ));
    await aTester.pumpAndSettle();

    expect(find.text('Work · since 09:15'), findsOneWidget);
    expect(find.byKey(const ValueKey('status.badge')), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('status.line')));
    await aTester.pumpAndSettle();
    expect(find.text('Start earlier'), findsOneWidget);

    final before = DateTime.now();
    await aTester.tap(find.text('15 min ago'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('status.pick.meal')));
    await aTester.pumpAndSettle();

    expect(api.created, [RoutineStatus.meal]);
    final start = api.createdStarts.single!;
    expect(before.difference(start).inMinutes, inInclusiveRange(14, 15));
    expect(find.text('Start earlier'), findsNothing);
  });
}
