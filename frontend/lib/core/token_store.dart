import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_config.dart';

class TokenStore
{
  static const String _tokenKey = 'session_token';
  static const List<String> _legacyKeys = ['jwt', 'auth_token'];

  final FlutterSecureStorage _storage;
  String? _cachedToken;
  bool _isLoaded = false;

  TokenStore(this._storage);

  Future<String?> read() async
  {
    if (AppConfig.isCookieMode)
    {
      return null;
    }

    if (!_isLoaded)
    {
      _cachedToken = await _storage.read(key: _tokenKey);
      _isLoaded = true;
    }

    return _cachedToken;
  }

  Future<void> write(String aToken) async
  {
    if (AppConfig.isCookieMode)
    {
      return;
    }

    _cachedToken = aToken;
    _isLoaded = true;
    await _storage.write(key: _tokenKey, value: aToken);
  }

  Future<void> clear() async
  {
    _cachedToken = null;
    _isLoaded = true;
    await _storage.delete(key: _tokenKey);
  }

  Future<void> purgeLegacy() async
  {
    for (final key in _legacyKeys)
    {
      await _storage.delete(key: key);
    }
  }
}
