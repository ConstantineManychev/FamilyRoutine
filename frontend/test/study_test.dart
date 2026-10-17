import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/study/study_block_panel.dart';
import 'package:family_routine/ui/study/study_format.dart';
import 'package:family_routine/ui/study/study_screen.dart';
import 'package:family_routine/ui/study/topic_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _narrowPhone = Size(320, 640);
const int _maxDepth = 3;

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _progress(String aPercent, {String? aDone, String? aTarget, String? aUnit, bool aIsAggregated = false}) => {
      'percent': aPercent,
      'done': aDone,
      'target': aTarget,
      'unit': aUnit,
      'is_aggregated': aIsAggregated,
    };

Map<String, dynamic> _topic(
  String aId,
  String aTitle,
  int aDepth,
  Map<String, dynamic> aProgress,
  {
    String? aParent,
    String aUnit = 'pages',
    String aTarget = '100',
    String aDone = '0',
    int aChildren = 0,
    int aNotes = 0,
  }
) => {
      'id': aId,
      'parent_id': aParent,
      'title': aTitle,
      'description': null,
      'unit': aUnit,
      'target': aTarget,
      'done': aDone,
      'depth': aDepth,
      'child_count': aChildren,
      'note_count': aNotes,
      'progress': aProgress,
      'updated_ts': '2026-10-15T08:00:00Z',
    };

List<Map<String, dynamic>> _topics() => [
      _topic('r1', 'Rust course', 1, _progress('40', aDone: '160', aTarget: '400', aUnit: 'pages', aIsAggregated: true),
          aUnit: 'percent', aChildren: 2, aNotes: 1),
      _topic('c1', 'Chapter 1', 2, _progress('100', aDone: '100', aTarget: '100', aUnit: 'pages'), aParent: 'r1', aDone: '100'),
      _topic('c2', 'Chapter 2', 2, _progress('20', aDone: '60', aTarget: '300', aUnit: 'pages', aIsAggregated: true),
          aParent: 'r1', aChildren: 1),
      _topic('g1', 'Section 2.1', 3, _progress('20', aDone: '60', aTarget: '300', aUnit: 'pages'),
          aParent: 'c2', aTarget: '300', aDone: '60', aNotes: 1),
      _topic('r2', 'English', 1, _progress('0', aDone: '0', aTarget: '100', aUnit: 'percent'), aUnit: 'percent'),
    ];

Map<String, dynamic> _note(String aId, String aTopicId, List<String> aPath, String aBody, String aTs) => {
      'id': aId,
      'topic_id': aTopicId,
      'topic_path': aPath,
      'body': aBody,
      'note_ts': aTs,
      'created_ts': aTs,
      'updated_ts': aTs,
    };

final Map<String, dynamic> _ownNote = _note('n1', 'r1', ['Rust course'], 'Course plan agreed', '2026-10-14T18:00:00');
final Map<String, dynamic> _deepNote = _note('n2', 'g1', ['Rust course', 'Chapter 2', 'Section 2.1'], 'Lifetimes clicked', '2026-10-16T10:05:00');

StudyTree _tree() => StudyTree.fromJson({'max_depth': _maxDepth, 'topics': _topics()});

class _CreatedNote
{
  final String topicId;
  final String body;
  final DateTime noteTs;

  const _CreatedNote(this.topicId, this.body, this.noteTs);
}

class _FakeApi extends ApiSvc
{
  final List<TopicDraft> created = [];
  final Map<String, TopicDraft> updated = {};
  final List<_CreatedNote> notes = [];
  final List<bool> noteScopes = [];

  _FakeApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<StudyTree> getStudyTree() async => _tree();

  @override
  Future<StudyTopic> createTopic(TopicDraft aDraft) async
  {
    created.add(aDraft);
    return StudyTopic.fromJson(_topics().last);
  }

  @override
  Future<StudyTopic> updateTopic(String aId, TopicDraft aDraft) async
  {
    updated[aId] = aDraft;
    return StudyTopic.fromJson(_topics().firstWhere((aTopic) => aTopic['id'] == aId));
  }

  @override
  Future<List<StudyNote>> getStudyNotes(String aTopicId, {bool aIsBranch = false}) async
  {
    noteScopes.add(aIsBranch);
    final notes = aIsBranch ? [_deepNote, _ownNote] : [_ownNote];
    return notes.map(StudyNote.fromJson).toList();
  }

  @override
  Future<StudyNote> createStudyNote(String aTopicId, String aBody, DateTime aNoteTs) async
  {
    notes.add(_CreatedNote(aTopicId, aBody, aNoteTs));
    return StudyNote.fromJson(_deepNote);
  }

  @override
  Future<MarkDetails> getMarkDetails(String aId) async => MarkDetails.fromJson({
        'mark': {'id': 's1', 'status': 'school', 'note': null, 'start_ts': '2026-10-16T09:00:00', 'end_ts': '2026-10-16T10:30:00'},
        'owner_id': 'u1',
        'owner_name': 'Alice',
        'is_mine': true,
        'is_details_hidden': false,
        'study': _markStudy(),
      });
}

Map<String, dynamic> _markStudy() => {
      'topics': _topics().where((aTopic) => aTopic['parent_id'] == null).toList(),
      'notes': [_deepNote],
    };

Widget _localized(Widget Function(BuildContext aContext) aBuild, _FakeApi aApi)
{
  return ProviderScope(
    overrides: [apiProv.overrideWithValue(aApi)],
    child: EasyLocalization(
      supportedLocales: const [Locale('en')],
      path: 'unused',
      assetLoader: const _EnglishLoader(),
      child: Builder(builder: aBuild),
    ),
  );
}

Widget _routed(String aLocation, _FakeApi aApi)
{
  final router = GoRouter(
    initialLocation: aLocation,
    routes: [
      GoRoute(
        path: '/app',
        builder: (_, __) => const Scaffold(body: Text('home')),
        routes: [
          GoRoute(path: 'study', builder: (_, __) => const StudyScreen()),
          GoRoute(path: 'study/:id', builder: (_, aState) => TopicScreen(key: ValueKey(aState.pathParameters['id']), topicId: aState.pathParameters['id']!)),
        ],
      ),
    ],
  );
  return _localized(
    (aContext) => MaterialApp.router(
      locale: aContext.locale,
      localizationsDelegates: aContext.localizationDelegates,
      supportedLocales: aContext.supportedLocales,
      theme: lightTheme,
      routerConfig: router,
    ),
    aApi,
  );
}

Widget _plain(Widget aChild, _FakeApi aApi)
{
  return _localized(
    (aContext) => MaterialApp(
      locale: aContext.locale,
      localizationsDelegates: aContext.localizationDelegates,
      supportedLocales: aContext.supportedLocales,
      theme: lightTheme,
      home: Scaffold(body: aChild),
    ),
    aApi,
  );
}

Future<void> _pump(WidgetTester aTester, Widget aApp, {Size aSize = const Size(900, 1400)}) async
{
  aTester.view.physicalSize = aSize;
  aTester.view.devicePixelRatio = 1;
  addTearDown(aTester.view.reset);
  await aTester.pumpWidget(aApp);
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

  test('tree knows its branches, paths and depth limits', ()
  {
    final tree = _tree();
    expect(tree.depthFirst().map((aTopic) => aTopic.id), ['r1', 'c1', 'c2', 'g1', 'r2']);
    expect(tree.branchIds('r1'), {'r1', 'c1', 'c2', 'g1'});
    expect(tree.pathTo('g1').map((aTopic) => aTopic.title), ['Rust course', 'Chapter 2', 'Section 2.1']);
    expect(tree.heightOf('r1'), 3);
    expect(tree.canAddChild(null), isTrue);
    expect(tree.canAddChild(tree.byId('c2')), isTrue);
    expect(tree.canAddChild(tree.byId('g1')), isFalse);
    expect(tree.canMoveUnder('c2', tree.byId('r2')), isTrue);
    expect(tree.canMoveUnder('r1', tree.byId('r2')), isFalse);
    expect(tree.canMoveUnder('r1', tree.byId('g1')), isFalse);
    expect(tree.canMoveUnder('c1', tree.byId('g1')), isFalse);
    expect(tree.canMoveUnder('g1', null), isTrue);
  });

  test('notes label their source below the viewed topic', ()
  {
    final note = StudyNote.fromJson(_deepNote);
    expect(note.sourceRelativeTo(1), ['Chapter 2', 'Section 2.1']);
    expect(note.sourceRelativeTo(2), ['Section 2.1']);
    expect(note.sourceRelativeTo(3), isEmpty);
  });

  test('percent topics always aim at one hundred', ()
  {
    const draft = TopicDraft(title: '  Grammar ', description: ' ', unit: StudyUnit.percent, target: 7, done: 30);
    expect(draft.toJson(), {'parent_id': null, 'title': 'Grammar', 'description': null, 'unit': 'percent', 'target': '100', 'done': '30.0'});
    final moved = TopicDraft.of(_tree().byId('c2')!).copyWith(isRoot: true);
    expect(moved.parentId, isNull);
  });

  test('block notes default into the block time', ()
  {
    final start = DateTime(2026, 10, 16, 9);
    final end = DateTime(2026, 10, 16, 10, 30);
    expect(noteTimeInBlock(DateTime(2026, 10, 16, 8), start, end), start);
    expect(noteTimeInBlock(DateTime(2026, 10, 16, 9, 40), start, end), DateTime(2026, 10, 16, 9, 40));
    expect(noteTimeInBlock(DateTime(2026, 10, 17), start, end), end);
    expect(noteTimeInBlock(DateTime(2026, 10, 17), start, null), DateTime(2026, 10, 17));
  });

  testWidgets('parent topic shows aggregated volume and collects branch notes with sources', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed('/app/study/r1', api));

    expect(find.byKey(const ValueKey('topic.percent')), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('160 of 400 pages'), findsOneWidget);
    expect(find.byKey(const ValueKey('topic.aggregated')), findsOneWidget);
    expect(find.byKey(const ValueKey('topic.progress')), findsNothing);
    expect(find.text('Chapter 1'), findsWidgets);
    expect(find.text('Course plan agreed'), findsOneWidget);
    expect(find.text('Lifetimes clicked'), findsNothing);

    await aTester.tap(find.text('Whole branch'));
    await aTester.pumpAndSettle();
    expect(api.noteScopes.last, isTrue);
    expect(find.text('Lifetimes clicked'), findsOneWidget);
    expect(find.text('Chapter 2 › Section 2.1'), findsOneWidget);
    expect(find.byKey(const ValueKey('note.source.n1')), findsNothing);
  });

  testWidgets('deepest topic blocks new levels but takes progress', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed('/app/study/g1', api));

    expect(find.byKey(const ValueKey('topic.depth_limit')), findsOneWidget);
    expect(aTester.widget<IconButton>(find.byKey(const ValueKey('topic.add_child'))).onPressed, isNull);
    expect(find.byKey(const ValueKey('topic.notes_scope')), findsNothing);

    await aTester.tap(find.byKey(const ValueKey('topic.progress')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('progress.add.10')));
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('progress.save')));
    await aTester.pumpAndSettle();
    expect(api.updated['g1']!.done, 70);
    expect(api.updated['g1']!.parentId, 'c2');
  });

  testWidgets('study screen nests topics, collapses branches and creates a topic', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed('/app/study', api));

    expect(find.text('Section 2.1'), findsOneWidget);
    expect(find.text('40% · 160 of 400 pages · 2 subtopics · 1 note'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('topic.expand.r1')));
    await aTester.pumpAndSettle();
    expect(find.text('Chapter 1'), findsNothing);
    expect(find.text('English'), findsOneWidget);

    await aTester.tap(find.byTooltip('New topic'));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('topic.title')), 'Algorithms book');
    await aTester.tap(find.byKey(const ValueKey('topic.unit.pages')));
    await aTester.pump();
    expect(aTester.widget<ElevatedButton>(find.byKey(const ValueKey('topic.save'))).onPressed, isNull);
    await aTester.enterText(find.byKey(const ValueKey('topic.target')), '320');
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('topic.save')));
    await aTester.pumpAndSettle();
    expect(api.created.single.title, 'Algorithms book');
    expect(api.created.single.unit, StudyUnit.pages);
    expect(api.created.single.target, 320);
    expect(api.created.single.parentId, isNull);
  });

  testWidgets('move offers only places that keep the tree valid', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed('/app/study/c2', api));

    await aTester.tap(find.byKey(const ValueKey('topic.menu')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('Move'));
    await aTester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text('To the top level')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('English')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('Rust course')), findsNothing);
    expect(find.descendant(of: dialog, matching: find.text('Section 2.1')), findsNothing);
    expect(find.descendant(of: dialog, matching: find.text('Chapter 1')), findsNothing);

    await aTester.tap(find.descendant(of: dialog, matching: find.text('English')));
    await aTester.pumpAndSettle();
    expect(api.updated['c2']!.parentId, 'r2');
  });

  testWidgets('school block lists topics and adds a note inside the block', (aTester) async
  {
    final api = _FakeApi();
    final study = MarkStudy.fromJson(_markStudy());
    await _pump(
      aTester,
      _plain(
        SingleChildScrollView(
          child: StudyBlockPanel(
            markId: 's1',
            startTs: DateTime(2026, 10, 16, 9),
            endTs: DateTime(2026, 10, 16, 10, 30),
            study: study,
            onOpenAll: (_) {},
          ),
        ),
        api,
      ),
    );
    expect(find.text('Rust course'), findsOneWidget);
    expect(find.text('Rust course › Chapter 2 › Section 2.1'), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('study.block.note')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.byKey(const ValueKey('topic.pick.g1')));
    await aTester.pumpAndSettle();
    await aTester.enterText(find.byKey(const ValueKey('note.body')), 'Borrow checker rules');
    await aTester.pump();
    await aTester.tap(find.byKey(const ValueKey('note.save')));
    await aTester.pumpAndSettle();
    expect(api.notes.single.topicId, 'g1');
    expect(api.notes.single.body, 'Borrow checker rules');
    expect(api.notes.single.noteTs, DateTime(2026, 10, 16, 10, 30));
  });

  testWidgets('topic screen fits a narrow phone', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _routed('/app/study/r1', api), aSize: _narrowPhone);
    expect(aTester.takeException(), isNull);
    final page = find.byType(Scrollable).first;
    await aTester.scrollUntilVisible(find.text('Whole branch'), 200, scrollable: page);
    await aTester.tap(find.text('Whole branch'));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    await aTester.scrollUntilVisible(find.text('Chapter 2 › Section 2.1'), 200, scrollable: page);
    expect(find.text('Chapter 2 › Section 2.1').hitTestable(), findsOneWidget);
  });

  test('study paths point into the study section', ()
  {
    expect(topicPath('r1'), '/app/study/r1');
    expect(studyPath, '/app/study');
  });
}
