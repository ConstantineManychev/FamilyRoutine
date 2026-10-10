import 'package:family_routine/core/route_guard.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/providers/auth_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const UserProf _user = UserProf(id: 'u1', email: 'a@b.c', fName: 'A', lName: 'B');

void main()
{
  group('resolveRedirect', ()
  {
    test('unknown status parks on splash and remembers the target', ()
    {
      final target = resolveRedirect(const AuthState.unknown(), Uri.parse('/app/wallets/42'));
      expect(target, '/splash?from=%2Fapp%2Fwallets%2F42');
    });

    test('legacy bank callback path keeps the bank response', ()
    {
      final target = resolveRedirect(const AuthState.unknown(), Uri.parse('/bank/callback?code=c1&state=s1'));
      expect(target, '/app/bank-callback?code=c1&state=s1');
    });

    test('splash itself is not redirected while unknown', ()
    {
      expect(resolveRedirect(const AuthState.unknown(), Uri.parse('/splash')), isNull);
    });

    test('unauthenticated user is sent to auth with the original target', ()
    {
      const state = AuthState(AuthStatus.unauthenticated);
      expect(resolveRedirect(state, Uri.parse('/app/places')), '/auth?from=%2Fapp%2Fplaces');
      expect(
        resolveRedirect(state, Uri.parse('/splash?from=%2Fapp%2Fplaces')),
        '/auth?from=%2Fapp%2Fplaces',
      );
    });

    test('explicit sign out does not carry the previous location', ()
    {
      const state = AuthState(AuthStatus.unauthenticated, isSignedOutByUser: true);
      expect(resolveRedirect(state, Uri.parse('/app/wallets/42')), '/auth');
    });

    test('authenticated user leaves auth and splash for the remembered target', ()
    {
      const state = AuthState(AuthStatus.authenticated, user: _user);
      expect(resolveRedirect(state, Uri.parse('/auth?from=%2Fapp%2Fplaces')), '/app/places');
      expect(resolveRedirect(state, Uri.parse('/splash')), '/app');
      expect(resolveRedirect(state, Uri.parse('/app/families')), isNull);
    });

    test('external or malformed targets are ignored', ()
    {
      expect(safeTarget('https://evil.example'), '/app');
      expect(safeTarget('//evil.example/app'), '/app');
      expect(safeTarget('/app\\..\\evil'), '/app');
      expect(safeTarget('/other'), '/app');
      expect(safeTarget(null), '/app');
      expect(safeTarget('/app/wallets'), '/app/wallets');
    });
  });
}
