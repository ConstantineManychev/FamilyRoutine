import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../api_svc.dart';
import 'push_platform.dart';

const String _workerPath = '/push_sw.js';
const String _workerScope = '/';
const String _openMessage = 'open-link';

PushPlatform createPushPlatform() => WebPush();

String _encodeKey(JSArrayBuffer aBuffer) => base64Url.encode(aBuffer.toDart.asUint8List()).replaceAll('=', '');

Uint8List _decodeKey(String aValue) => base64Url.decode(base64Url.normalize(aValue));

bool _isSameKey(JSArrayBuffer? aCurrent, Uint8List aWanted)
{
  if (aCurrent == null)
  {
    return false;
  }
  final current = aCurrent.toDart.asUint8List();
  if (current.length != aWanted.length)
  {
    return false;
  }
  for (var index = 0; index < current.length; index++)
  {
    if (current[index] != aWanted[index])
    {
      return false;
    }
  }
  return true;
}

class WebPush implements PushPlatform
{
  OpenLinkHandler? _onOpen;
  bool _isListening = false;

  bool get _isSupported =>
      web.window.navigator.has('serviceWorker') && web.window.has('PushManager') && web.window.has('Notification');

  web.ServiceWorkerContainer get _container => web.window.navigator.serviceWorker;

  @override
  PushMode get mode => _isSupported ? PushMode.web : PushMode.none;

  @override
  Future<PushPermission> permission() async
  {
    if (!_isSupported)
    {
      return PushPermission.unsupported;
    }
    return switch (web.Notification.permission)
    {
      'granted' => PushPermission.granted,
      'denied' => PushPermission.denied,
      _ => PushPermission.prompt,
    };
  }

  Future<web.PushSubscription?> _current() async
  {
    final registration = await _container.getRegistration(_workerScope).toDart;
    return registration == null ? null : await registration.pushManager.getSubscription().toDart;
  }

  @override
  Future<bool> isEnabled(String aUserId) async
  {
    if (!_isSupported || web.Notification.permission != 'granted' || await pushUser() != aUserId)
    {
      return false;
    }
    return await _current() != null;
  }

  Future<web.PushSubscription> _subscribe(String aKey) async
  {
    await _container.register(_workerPath.toJS).toDart;
    final registration = await _container.ready.toDart;
    final key = _decodeKey(aKey);
    final existing = await registration.pushManager.getSubscription().toDart;
    if (existing != null)
    {
      if (_isSameKey(existing.options.applicationServerKey, key))
      {
        return existing;
      }
      await existing.unsubscribe().toDart;
    }
    return registration.pushManager
        .subscribe(web.PushSubscriptionOptionsInit(userVisibleOnly: true, applicationServerKey: key.toJS))
        .toDart;
  }

  Future<void> _register(ApiSvc aApi, web.PushSubscription aSubscription) async
  {
    final p256dh = aSubscription.getKey('p256dh');
    final auth = aSubscription.getKey('auth');
    if (p256dh == null || auth == null)
    {
      throw StateError('push subscription has no keys');
    }
    await aApi.addPushSub(aEndpoint: aSubscription.endpoint, aP256dh: _encodeKey(p256dh), aAuth: _encodeKey(auth));
  }

  @override
  Future<bool> enable(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async
  {
    _listen();
    if (!_isSupported)
    {
      return false;
    }
    final key = await aApi.getPushKey();
    if (key == null)
    {
      return false;
    }
    final answer = (await web.Notification.requestPermission().toDart).toDart;
    if (answer != 'granted')
    {
      return false;
    }
    await _register(aApi, await _subscribe(key));
    await rememberPushUser(aUserId);
    return true;
  }

  @override
  Future<void> disable(ApiSvc aApi) async
  {
    await rememberPushUser(null);
    if (!_isSupported)
    {
      return;
    }
    final subscription = await _current();
    if (subscription == null)
    {
      return;
    }
    try
    {
      await aApi.removePushSub(subscription.endpoint);
    }
    finally
    {
      await subscription.unsubscribe().toDart;
    }
  }

  @override
  Future<void> sync(ApiSvc aApi, NoticeTexts aTexts, String aUserId) async
  {
    _listen();
    if (!_isSupported || web.Notification.permission != 'granted')
    {
      return;
    }
    final subscription = await _current();
    if (subscription == null)
    {
      return;
    }
    if (await pushUser() != aUserId)
    {
      await subscription.unsubscribe().toDart;
      return;
    }
    final key = await aApi.getPushKey();
    if (key == null)
    {
      return;
    }
    await _register(aApi, await _subscribe(key));
  }

  @override
  Future<void> signOut(ApiSvc aApi) => disable(aApi);

  @override
  void onOpen(OpenLinkHandler aHandler)
  {
    _onOpen = aHandler;
    _listen();
  }

  void _listen()
  {
    if (_isListening || !_isSupported)
    {
      return;
    }
    _isListening = true;
    _container.addEventListener(
      'message',
      ((web.MessageEvent aEvent)
      {
        final data = aEvent.data.dartify();
        if (data is Map && data['type'] == _openMessage)
        {
          final link = data['link'];
          if (link is String && isAppLink(link))
          {
            _onOpen?.call(link);
          }
        }
      }).toJS,
    );
  }
}
