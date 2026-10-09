import '../providers/auth_provider.dart';

const String splashPath = '/splash';
const String authPath = '/auth';
const String homePath = '/app';
const String fromParam = 'from';

String? resolveRedirect(AuthState aAuth, Uri aUri)
{
  final path = aUri.path;
  final isSplash = path == splashPath;
  final isAuth = path == authPath;

  switch (aAuth.status)
  {
    case AuthStatus.unknown:
      return isSplash ? null : _withFrom(splashPath, _ownTarget(aUri));
    case AuthStatus.unauthenticated:
      if (isAuth)
      {
        return null;
      }
      if (aAuth.isSignedOutByUser)
      {
        return authPath;
      }
      final from = isSplash ? aUri.queryParameters[fromParam] : _ownTarget(aUri);
      return _withFrom(authPath, from);
    case AuthStatus.authenticated:
      if (isSplash || isAuth)
      {
        return safeTarget(aUri.queryParameters[fromParam]);
      }
      return null;
  }
}

String safeTarget(String? aFrom)
{
  final isInternal = aFrom != null
      && aFrom.startsWith(homePath)
      && !aFrom.startsWith('//')
      && !aFrom.contains('://')
      && !aFrom.contains('\\');

  return isInternal ? aFrom : homePath;
}

String? _ownTarget(Uri aUri)
{
  final target = aUri.toString();
  return target.startsWith(homePath) ? target : null;
}

String _withFrom(String aPath, String? aFrom)
{
  final target = safeTarget(aFrom);
  if (aFrom == null || target == homePath)
  {
    return aPath;
  }
  return Uri(path: aPath, queryParameters: {fromParam: target}).toString();
}
