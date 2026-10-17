import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:family_routine/core/api_svc.dart';
import 'package:family_routine/core/push/push_platform.dart';
import 'package:family_routine/core/token_store.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/api_prov.dart';
import 'package:family_routine/providers/auth_provider.dart';
import 'package:family_routine/providers/push_prov.dart';
import 'package:family_routine/ui/common/app_theme.dart';
import 'package:family_routine/ui/notify/notifications_screen.dart';
import 'package:family_routine/ui/notify/notify_bell.dart';
import 'package:family_routine/ui/notify/notify_format.dart';
import 'package:family_routine/ui/notify/notify_settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EnglishLoader extends AssetLoader
{
  const _EnglishLoader();

  @override
  Future<Map<String, dynamic>> load(String aPath, Locale aLocale) async =>
      jsonDecode(File('assets/i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
}

Map<String, dynamic> _notice(String aId, String aKind, Map<String, dynamic> aParams, {bool aIsRead = false, String aLink = '/app/stock'}) => {
      'id': aId,
      'kind': aKind,
      'title': 'server title',
      'body': 'server body',
      'link': aLink,
      'params': aParams,
      'created_ts': '2026-10-16T09:00:00Z',
      'is_read': aIsRead,
    };

Map<String, dynamic> _expiringParams() => {
      'day': 'tomorrow',
      'family_name': 'Home',
      'more': 2,
      'items': [
        {'title': 'Kefir', 'qty': '500', 'measure': 'ml'},
        {'title': 'Eggs', 'qty': '6', 'measure': 'pcs'},
      ],
    };

class _FakeApi extends ApiSvc
{
  final List<Map<String, Object?>> saved = [];
  final List<(List<String>, bool)> reads = [];
  NotifySettings settings = const NotifySettings(tz: 'Europe/Kyiv', lang: 'en', isWebPush: true);

  _FakeApi() : super(Dio(), TokenStore(const FlutterSecureStorage()));

  @override
  Future<NoticeInbox> getNotices({int aLimit = 50}) async => NoticeInbox.fromJson({
        'unread': 1,
        'items': [
          _notice('n1', 'expiring', _expiringParams()),
          _notice('n2', 'expired', {'items': [{'title': 'Milk', 'qty': '600', 'measure': 'g'}], 'more': 0}, aIsRead: true, aLink: '/app/stock/history'),
        ],
      });

  @override
  Future<void> markNoticesRead({List<String> aIds = const [], bool aIsAll = false}) async => reads.add((aIds, aIsAll));

  @override
  Future<NotifySettings> getNotifySettings() async => settings;

  @override
  Future<NotifySettings> saveNotifySettings(Map<String, Object?> aPatch) async
  {
    saved.add(aPatch);
    settings = NotifySettings.fromJson({
      'tz': settings.tz,
      'lang': settings.lang,
      'is_plan': aPatch['is_plan'] ?? settings.isPlan,
      'plan_lead_min': aPatch['plan_lead_min'] ?? settings.planLeadMin,
      'is_workout': settings.isWorkout,
      'workout_lead_min': settings.workoutLeadMin,
      'is_expiring': aPatch['is_expiring'] ?? settings.isExpiring,
      'is_expired': settings.isExpired,
      'is_web_push': true,
      'push_subs': 0,
    });
    return settings;
  }

  @override
  Future<String?> getPushKey() async => 'BKey';
}

class _FakePush implements PushPlatform
{
  bool isOn = false;
  int syncs = 0;

  @override
  PushMode get mode => PushMode.web;

  @override
  Future<PushPermission> permission() async => isOn ? PushPermission.granted : PushPermission.prompt;

  @override
  Future<bool> isEnabled(String aUserId) async => isOn;

  @override
  Future<bool> enable(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async => isOn = true;

  @override
  Future<void> disable(ApiSvc aApi) async => isOn = false;

  @override
  Future<void> sync(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async => syncs++;

  @override
  Future<void> signOut(ApiSvc aApi) async => isOn = false;

  @override
  void onOpen(OpenLinkHandler aHandler) {}
}

class _SignedIn extends AuthNotifier
{
  @override
  AuthState build() => const AuthState(
        AuthStatus.authenticated,
        user: UserProf(id: 'u1', email: 'a@example.com', fName: 'Ann', lName: 'Lee'),
      );
}

Widget _app(Widget aScreen, _FakeApi aApi, _FakePush aPush)
{
  final router = GoRouter(
    initialLocation: '/app/screen',
    routes: [
      GoRoute(
        path: '/app',
        builder: (_, __) => const Scaffold(body: Text('home')),
        routes: [
          GoRoute(path: 'screen', builder: (_, __) => aScreen),
          GoRoute(path: 'notifications', builder: (_, __) => const Scaffold(body: Text('inbox'))),
          GoRoute(path: 'stock', builder: (_, __) => const Scaffold(body: Text('stock page'))),
          GoRoute(path: 'settings', builder: (_, __) => const Scaffold(body: Text('settings page'))),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      apiProv.overrideWithValue(aApi),
      pushPlatformProv.overrideWithValue(aPush),
      authProv.overrideWith(_SignedIn.new),
    ],
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

Future<void> _pump(WidgetTester aTester, Widget aApp) async
{
  aTester.view.physicalSize = const Size(900, 1400);
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

  testWidgets('notices render in the app language from their params', (aTester) async
  {
    await _pump(aTester, _app(const SizedBox.shrink(), _FakeApi(), _FakePush()));
    final start = DateTime(2026, 10, 16, 18, 30);
    final plan = UpcomingNotice.fromJson({
      'key': 'plan:1',
      'kind': 'plan',
      'due_ts': '2026-10-16T15:00:00Z',
      'title': 'x',
      'body': 'x',
      'link': '/app/planner',
      'params': {'title': 'Call', 'start_ts': start.toUtc().toIso8601String()},
    });
    expect(renderNotice(plan), ('Call', 'Starts at 18:30'));
    final workout = NoticeContent(kind: NotifyKind.workout, title: 'x', body: 'x', link: '/app/planner', params: plan.params);
    expect(renderNotice(workout).$1, 'Workout: Call');
    final expiring = AppNotice.fromJson(_notice('n1', 'expiring', _expiringParams()));
    expect(renderNotice(expiring), ('Expires tomorrow', 'Home: Kefir 500 ml, Eggs 6 pcs and 2 more'));
    final today = AppNotice.fromJson(_notice('n3', 'expiring', {..._expiringParams(), 'day': 'today', 'family_name': null, 'more': 0}));
    expect(renderNotice(today), ('Expires today', 'Kefir 500 ml, Eggs 6 pcs'));
    final bare = AppNotice.fromJson(_notice('n4', 'expired', const {}));
    expect(renderNotice(bare), ('Written off as expired', 'server body'));
    expect(leadLabel(0), 'at start time');
    expect(leadLabel(15), '15 min before');
    expect(leadLabel(120), '2 h before');
    expect(isAppLink('/app/stock'), isTrue);
    expect(isAppLink('https://evil.example/app/x'), isFalse);
    expect(isAppLink('/app//evil.example'), isFalse);
  });

  testWidgets('the inbox marks a notice read and opens its link', (aTester) async
  {
    final api = _FakeApi();
    await _pump(aTester, _app(const NotificationsScreen(), api, _FakePush()));

    expect(find.text('Expires tomorrow'), findsOneWidget);
    expect(find.text('Home: Kefir 500 ml, Eggs 6 pcs and 2 more'), findsOneWidget);
    expect(find.text('Written off as expired'), findsOneWidget);
    expect(find.byKey(const ValueKey('notify.device')), findsOneWidget);

    await aTester.tap(find.byKey(const ValueKey('notify.read_all')));
    await aTester.pumpAndSettle();
    expect(api.reads.single.$1, isEmpty);
    expect(api.reads.single.$2, isTrue);

    await aTester.tap(find.byKey(const ValueKey('notify.item.n1')));
    await aTester.pumpAndSettle();
    expect(api.reads.last.$1, ['n1']);
    expect(api.reads.last.$2, isFalse);
    expect(find.text('stock page'), findsOneWidget);
  });

  testWidgets('settings save each reminder type and lead time', (aTester) async
  {
    final api = _FakeApi();
    final push = _FakePush();
    await _pump(aTester, _app(const SingleChildScrollView(child: NotifySettingsSection()), api, push));

    expect(find.text('Planner events'), findsOneWidget);
    expect(find.text('Time zone for reminders and expiry dates: Europe/Kyiv'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('notify.is_expiring')));
    await aTester.pumpAndSettle();
    expect(api.saved.single, {'is_expiring': false});
    expect(push.syncs, 1);

    await aTester.tap(find.byKey(const ValueKey('notify.plan_lead')));
    await aTester.pumpAndSettle();
    await aTester.tap(find.text('30 min before').last);
    await aTester.pumpAndSettle();
    expect(api.saved.last, {'plan_lead_min': 30});

    await aTester.tap(find.byKey(const ValueKey('notify.is_plan')));
    await aTester.pumpAndSettle();
    expect(api.saved.last, {'is_plan': false});
    final lead = aTester.widget<DropdownButtonFormField<int>>(find.byKey(const ValueKey('notify.plan_lead')));
    expect(lead.onChanged, isNull);
  });

  testWidgets('push is switched on and off for this device', (aTester) async
  {
    final api = _FakeApi();
    final push = _FakePush();
    await _pump(aTester, _app(const SingleChildScrollView(child: NotifySettingsSection()), api, push));

    expect(find.textContaining('System notifications are off on this device'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('notify.device_toggle')));
    await aTester.pumpAndSettle();
    expect(push.isOn, isTrue);
    expect(find.text('System notifications are on for this device.'), findsOneWidget);
    expect(find.text('Turn off'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('notify.device_toggle')));
    await aTester.pumpAndSettle();
    expect(push.isOn, isFalse);
  });

  testWidgets('notification settings and inbox fit a narrow phone', (aTester) async
  {
    aTester.view.physicalSize = const Size(320, 640);
    aTester.view.devicePixelRatio = 1;
    addTearDown(aTester.view.reset);
    final api = _FakeApi();
    await aTester.pumpWidget(_app(const SingleChildScrollView(padding: EdgeInsets.all(16), child: NotifySettingsSection()), api, _FakePush()));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.byKey(const ValueKey('notify.plan_lead')), findsOneWidget);
    await aTester.pumpWidget(_app(const NotificationsScreen(), api, _FakePush()));
    await aTester.pumpAndSettle();
    expect(aTester.takeException(), isNull);
    expect(find.text('Expires tomorrow'), findsOneWidget);
  });

  testWidgets('the bell shows unread notices and opens the inbox', (aTester) async
  {
    await _pump(aTester, _app(const Scaffold(body: Center(child: NotifyBell())), _FakeApi(), _FakePush()));
    expect(find.text('1'), findsOneWidget);
    expect(find.byTooltip('Notifications: 1 unread'), findsOneWidget);
    await aTester.tap(find.byKey(const ValueKey('notify.bell')));
    await aTester.pumpAndSettle();
    expect(find.text('inbox'), findsOneWidget);
  });
}
