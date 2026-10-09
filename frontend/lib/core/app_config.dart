import 'package:flutter/foundation.dart';

class AppConfig
{
  static const String _apiUrlOverride = String.fromEnvironment('API_URL');
  static const String nativeDefaultApiUrl = 'http://127.0.0.1:3000';
  static const String csrfHeader = 'X-Requested-With';
  static const String csrfValue = 'FamilyRoutine';

  static String get apiBaseUrl
  {
    if (_apiUrlOverride.isNotEmpty)
    {
      return _apiUrlOverride;
    }
    return kIsWeb ? Uri.base.origin : nativeDefaultApiUrl;
  }

  static bool get isCookieMode => kIsWeb;
}
