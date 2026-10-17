import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/work/task_sheet.dart';
import 'package:family_routine/ui/work/work_block_panel.dart';
import 'package:family_routine/ui/work/work_format.dart';
import 'package:family_routine/ui/work/work_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(320, 640);
final DateTime _day = DateTime(2026, 10, 16);

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _task(String aId, String aKind, String aTitle, {String aStart = '2026-10-14', String? aDone, String? aReport}) => {
      'id': aId,
      'kind': aKind,
      'title': aTitle,
      'note': null,
      'start_on': aStart,
      'done_on': aDone,
      'done_ts': aDone == null ? null : '${aDone}T15:00:00Z',
      'deleted_ts': null,
      'created_ts': '2026-10-14T08:00:00Z',
      'updated_ts': '2026-10-14T08:00:00Z',
      'last_report': aReport,
      'last_report_ts': aReport == null ? null : '2026-10-15T10:00:00Z',
      'report_count': aReport == null ? 0 : 1,
    };

Map<String, dynamic> _event(String aKind, {String? aField, String? aOld, String? aNew, String? aReport, String? aMark}) => {
      'id': 'e-$aKind-${aField ?? ''}',
      'kind': aKind,
      'field': aField,
      'old_value': aOld,
      'new_value': aNew,
      'report': aReport,
      'event_on': '2026-10-15',
      'event_ts': '2026-10-15T09:30:00',
      'status_mark_id': aMark,
    };

Map<String, dynamic> _dayJson() => {
      'date': '2026-10-16',
      'general': [_task('g1', 'general', 'Quarterly report', aReport: 'Collected numbers')],
      'day': [_task('d1', 'day', 'Stand-up', aStart: '2026-10-16')],
    };

Map<String, dynamic> _details({String? aDone}) => {
      'task': _task('g1', 'general', 'Quarterly report', aDone: aDone),
      'events': [
        _event('created', aNew: 'Report'),
        _event('edited', aField: 'title', aOld: 'Report', aNew: 'Quarterly report'),
        _event('edited', aField: 'kind', aOld: 'day', aNew: 'general'),
        _event('edited', aField: 'note', aNew: 'For the board'),
        _event('progress', aReport: 'Collected numbers', aMark: 'w1'),
        if (aDone != null) _event('done', aReport: 'Sent'),
      ],
    };

class _Log
{
  final String id;
  final TaskAction action;
  final String? report;
  final String? markId;

  const _Log(this.id, this.action, this.report, this.markId);
}

class _FakeApi extends ApiSvc
{
  final List<_Log> logs = [];
  final List<TaskDraft> created = [];
  bool isDone = false;

  _FakeApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<WorkDay> getWorkDay(DateTime aDate) async => WorkDay.fromJson(_dayJson());

  @override
  Future<TaskDetails> getTask(String aId) async => TaskDetails.fromJson(_details(aDone: isDone ? '2026-10-16' : null));

  @override
  Future<TaskDetails> createTask(TaskDraft aDraft) async
  {
    created.add(aDraft);
    return TaskDetails.fromJson(_details());
  }

  @override
  Future<TaskDetails> logTask(String aId, TaskAction aAction, DateTime aDate, {String? aReport, String? aMarkId}) async
  {
    logs.add(_Log(aId, aAction, aReport, aMarkId));
    isDone = aAction == TaskAction.done;
    return TaskDetails.fromJson(_details(aDone: isDone ? '2026-10-16' : null));
  }

  @override
  Future<MarkDetails> getMarkDetails(String aId) async => MarkDetails.fromJson({
        'mark': {'id': 'w1', 'status': 'work', 'note': null, 'start_ts': '2026-10-16T09:00:00', 'end_ts': null},
        'owner_id': 'u1',
        'owner_name': 'Alice',
        'is_mine': true,
        'is_details_hidden': false,
        'work': {..._dayJson(), 'logged': const []},
      });
}

Widget _app(Widget aChild, _FakeApi aApi)
{
  return ProviderScope(
    overrides: [apiProv.overrideWithValue(aApi)],
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

Future<void> _pump(WidgetTester aTester, Widget aChild, _FakeApi aApi, {Size aSize = const Size(900, 1200)}) async
{
  aTester.view.physicalSize = aSize;
  aTester.view.devicePixelRatio = 1;
  addTearDown(aTester.view.reset);
  await aTester.pumpWidget(_app(aChild, aApi));
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

  test('work day separates kinds and knows what is done on the day', ()
  {
    final day = WorkDay.fromJson(_dayJson());
    expect(day.general.single.carriedDays(_day), 2);
    expect(day.day.single.carriedDays(_day), 0);
    expect(day.openCount, 2);
    final done = WorkTask.fromJson(_task('g2', 'general', 'X', aDone: '2026-10-17'));
    expect(done.isDoneOn(_day), isFalse);
    expect(done.isDoneOn(DateTime(2026, 10, 17)), isTrue);
    expect(
      TaskDraft(kind: TaskKind.general, title: '  Plan  ', note: ' ', date: _day).toJson(),
      {'kind': 'general', 'title': 'Plan', 'note': null, 'date': '2026-10-16'},
    );
  });

  testWidgets('history reads as before and after with reports and block marks', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, Builder(builder: (aContext) => TextButton(onPressed: () => openTaskSheet(aContext, 'g1', _day), child: const Text('open'))), api);
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();

    expect(find.text('Title: «Report» → «Quarterly report»'), findsOneWidget);
    expect(find.text('Type: Day task → Ongoing'), findsOneWidget);
    expect(find.text('Details: empty → «For the board»'), findsOneWidget);
    expect(find.text('Report for Oct 15'), findsOneWidget);
    expect(find.text('Collected numbers'), findsOneWidget);
    expect(find.textContaining('in a “Work” block'), findsOneWidget);
    expect(find.text('carried over since Oct 14, day 3'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('task.done')));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('task.report')), 'Sent to the board');
    await aTester.tap(find.byKey(const ValueKey('task.report_save')));
    await aTester.pumpAndSettle();
    expect(api.logs.single.action, TaskAction.done);
    expect(api.logs.single.report, 'Sent to the board');
    expect(find.text('Done on Oct 15'), findsOneWidget);
    expect(find.byKey(const ValueKey('task.reopen')), findsOneWidget);
  });

  testWidgets('progress needs a written report', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, Builder(builder: (aContext) => TextButton(onPressed: () => openTaskSheet(aContext, 'g1', _day), child: const Text('open'))), api);
    await aTester.tap(find.text('open'));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('task.progress')));
    await aTester.pumpAndSettle();
    expect(aTester.widget<ElevatedButton>(find.byKey(const ValueKey('task.report_save'))).onPressed, isNull);
    await aTester.enterText(find.byKey(const ValueKey('task.report')), 'Drafted the summary');
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('task.report_save')));
    await aTester.pumpAndSettle();
    expect(api.logs.single.action, TaskAction.progress);
    expect(api.logs.single.report, 'Drafted the summary');
  });

  testWidgets('tasks screen lists both kinds and creates a day task', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, WorkScreen(initialDate: _day), api);
    expect(find.text('Tasks for the day'), findsOneWidget);
    expect(find.text('Ongoing tasks'), findsOneWidget);
    expect(find.text('Stand-up'), findsOneWidget);
    expect(find.textContaining('carried over since Oct 14, day 3'), findsOneWidget);
    expect(find.textContaining('latest: Collected numbers'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('work.add.day')));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('task.title')), 'Call the bank');
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('task.save')));
    await aTester.pumpAndSettle();
    expect(api.created.single.kind, TaskKind.day);
    expect(api.created.single.title, 'Call the bank');
    expect(api.created.single.date, _day);
  });

  testWidgets('work block panel logs progress into the block', (aTester) async
  {
    final api = _FakeApi();
    final work = MarkWork.fromJson({..._dayJson(), 'logged': [
      {'task_id': 'g1', 'task_title': 'Quarterly report', 'kind': 'progress', 'report': 'Collected numbers', 'event_ts': '2026-10-16T10:15:00'},
    ]});
    await _pump(aTester, SingleChildScrollView(child: WorkBlockPanel(markId: 'w1', work: work, onOpenAll: (_) {})), api);
    expect(find.text('Tasks for this day: 2 open'), findsOneWidget);
    expect(find.text('Quarterly report — Collected numbers'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('task.report.d1')));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('task.report')), 'Ran the stand-up');
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('task.report_save')));
    await aTester.pumpAndSettle();
    expect(api.logs.single.id, 'd1');
    expect(api.logs.single.action, TaskAction.progress);
    expect(api.logs.single.markId, 'w1');
  });

  testWidgets('tasks screen and task sheet fit a narrow phone', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, WorkScreen(initialDate: _day), api, aSize: _narrowPhone);
    expect(aTester.takeException(), isNull);
    await aTester.tap(find.text('Stand-up'));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.byKey(const ValueKey('task.done')).hitTestable(), findsOneWidget);
  });

  test('work path carries the date', ()
  {
    expect(workPath(_day), '/app/work?date=2026-10-16');
  });
}
