import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../api_svc.dart';
import 'push_platform.dart';

const String _channelId = 'reminders';
const String _launcherIcon = '@mipmap/ic_launcher';
const int _maxScheduled = 60;
const int _idMask = 0x7fffffff;

PushPlatform createPushPlatform() => Platform.isAndroid ? LocalPush() : const NoPush();

int _noticeId(String aKey)
{
  var hash = 0x811c9dc5;
  for (final unit in aKey.codeUnits)
  {
    hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
  }
  return hash & _idMask;
}

class LocalPush implements PushPlatform
{
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  Future<bool>? _ready;
  OpenLinkHandler? _onOpen;
  String? _pendingLink;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<bool> _init() => _ready ??= _initialize();

  Future<bool> _initialize() async
  {
    final isReady = await _plugin.initialize(
          settings: const InitializationSettings(android: AndroidInitializationSettings(_launcherIcon)),
          onDidReceiveNotificationResponse: (aResponse) => _open(aResponse.payload),
        ) ??
        false;
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false)
    {
      _open(launch?.notificationResponse?.payload);
    }
    return isReady;
  }

  void _open(String? aLink)
  {
    if (!isAppLink(aLink))
    {
      return;
    }
    final handler = _onOpen;
    if (handler == null)
    {
      _pendingLink = aLink;
    }
    else
    {
      handler(aLink!);
    }
  }

  @override
  PushMode get mode => PushMode.local;

  @override
  Future<PushPermission> permission() async
  {
    await _init();
    final isOn = await _android?.areNotificationsEnabled() ?? false;
    return isOn ? PushPermission.granted : PushPermission.prompt;
  }

  @override
  Future<bool> isEnabled(String aUserId) async =>
      await pushUser() == aUserId && await permission() == PushPermission.granted;

  @override
  Future<bool> enable(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async
  {
    await _init();
    final isGranted = await _android?.requestNotificationsPermission() ?? false;
    if (!isGranted)
    {
      return false;
    }
    await rememberPushUser(aUserId);
    await sync(aApi, aTexts, aUserId);
    return true;
  }

  @override
  Future<void> disable(ApiSvc aApi) async
  {
    await rememberPushUser(null);
    await _init();
    await _plugin.cancelAll();
  }

  @override
  Future<void> sync(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async
  {
    await _init();
    if (await pushUser() != aUserId || await permission() != PushPermission.granted)
    {
      return;
    }
    final upcoming = await aApi.getUpcomingNotices();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        aTexts.channelName,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _plugin.cancelAll();
    for (final notice in upcoming.take(_maxScheduled))
    {
      final (title, body) = aTexts.render(notice);
      await _plugin.zonedSchedule(
        id: _noticeId(notice.key),
        scheduledDate: tz.TZDateTime.from(notice.dueTs.toUtc(), tz.UTC),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        title: title,
        body: body,
        payload: notice.link,
      );
    }
  }

  @override
  Future<void> signOut(ApiSvc aApi) => disable(aApi);

  @override
  void onOpen(OpenLinkHandler aHandler)
  {
    _onOpen = aHandler;
    final pending = _pendingLink;
    _pendingLink = null;
    if (pending != null)
    {
      aHandler(pending);
    }
    _init();
  }
}
