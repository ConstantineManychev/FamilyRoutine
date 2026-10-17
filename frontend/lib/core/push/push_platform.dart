import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models.dart';
import '../api_svc.dart';
import 'push_stub.dart'
    if (dart.library.js_interop) 'push_web.dart'
    if (dart.library.io) 'push_io.dart' as impl;

const String _userPrefKey = 'push.user';

enum PushMode
{
  none,
  web,
  local,
}

enum PushPermission
{
  unsupported,
  prompt,
  granted,
  denied,
}

typedef OpenLinkHandler = void Function(String aLink);

class NoticeTexts
{
  final String channelName;
  final (String, String) Function(NoticeContent aNotice) render;

  const NoticeTexts({required this.channelName, required this.render});
}

bool isAppLink(String? aLink) => aLink != null && aLink.startsWith('/app/') && !aLink.contains('//');

Future<String?> pushUser() async
{
  try
  {
    return (await SharedPreferences.getInstance()).getString(_userPrefKey);
  }
  catch (_)
  {
    return null;
  }
}

Future<void> rememberPushUser(String? aUserId) async
{
  try
  {
    final prefs = await SharedPreferences.getInstance();
    if (aUserId == null)
    {
      await prefs.remove(_userPrefKey);
    }
    else
    {
      await prefs.setString(_userPrefKey, aUserId);
    }
  }
  catch (_)
  {
    return;
  }
}

abstract class PushPlatform
{
  PushMode get mode;

  Future<PushPermission> permission();

  Future<bool> isEnabled(String aUserId);

  Future<bool> enable(ApiSvc aApi, NoticeTexts aTexts, String aUserId);

  Future<void> disable(ApiSvc aApi);

  Future<void> sync(ApiSvc aApi, NoticeTexts aTexts, String aUserId);

  Future<void> signOut(ApiSvc aApi);

  void onOpen(OpenLinkHandler aHandler);
}

class NoPush implements PushPlatform
{
  const NoPush();

  @override
  PushMode get mode => PushMode.none;

  @override
  Future<PushPermission> permission() async => PushPermission.unsupported;

  @override
  Future<bool> isEnabled(String aUserId) async => false;

  @override
  Future<bool> enable(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async => false;

  @override
  Future<void> disable(ApiSvc aApi) async {}

  @override
  Future<void> sync(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async {}

  @override
  Future<void> signOut(ApiSvc aApi) async {}

  @override
  void onOpen(OpenLinkHandler aHandler) {}
}

PushPlatform createPushPlatform() => impl.createPushPlatform();
