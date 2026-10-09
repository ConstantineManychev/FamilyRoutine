import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_error.dart';
import '../core/app_config.dart';
import '../domain/models.dart';
import 'api_prov.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState
{
  final AuthStatus status;
  final UserProf? user;
  final bool isSignedOutByUser;

  const AuthState(this.status, {this.user, this.isSignedOutByUser = false});

  const AuthState.unknown() : this(AuthStatus.unknown);

  bool get isAuthenticated => status == AuthStatus.authenticated;
}

class AuthNotifier extends Notifier<AuthState>
{
  @override
  AuthState build()
  {
    Future.microtask(restore);
    return const AuthState.unknown();
  }

  Future<void> restore() async
  {
    final api = ref.read(apiProv);

    try
    {
      await api.purgeLegacyTokens();

      if (!AppConfig.isCookieMode && !await api.hasStoredToken())
      {
        state = const AuthState(AuthStatus.unauthenticated);
        return;
      }

      final user = await api.getMe();
      state = AuthState(AuthStatus.authenticated, user: user);
    }
    catch (aError)
    {
      if (ApiException.from(aError).isUnauthenticated)
      {
        await api.clearToken();
      }
      state = const AuthState(AuthStatus.unauthenticated);
    }
  }

  Future<void> login(String aEmail, String aPassword) async
  {
    final user = await ref.read(apiProv).login(aEmail, aPassword);
    state = AuthState(AuthStatus.authenticated, user: user);
  }

  Future<void> logout() async
  {
    await ref.read(apiProv).logout();
    state = const AuthState(AuthStatus.unauthenticated, isSignedOutByUser: true);
  }

  void handleUnauthorized()
  {
    if (state.status != AuthStatus.authenticated)
    {
      return;
    }

    ref.read(apiProv).clearToken();
    state = const AuthState(AuthStatus.unauthenticated);
  }
}

final NotifierProvider<AuthNotifier, AuthState> authProv = NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
