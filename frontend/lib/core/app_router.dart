import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models.dart';
import '../providers/auth_provider.dart';
import '../ui/auth/auth_screen.dart';
import '../ui/auth/splash_screen.dart';
import '../ui/dicts/cities_dict_screen.dart';
import '../ui/dicts/exercise_detail_screen.dart';
import '../ui/dicts/exercises_screen.dart';
import '../ui/dicts/item_detail_screen.dart';
import '../ui/dicts/items_screen.dart';
import '../ui/dicts/streets_dict_screen.dart';
import '../ui/finance/receipt_detail_screen.dart';
import '../ui/finance/receipts_screen.dart';
import '../ui/finance/transactions_screen.dart';
import '../ui/home/dashboard_screen.dart';
import '../ui/home/fam_detail_screen.dart';
import '../ui/home/fam_groups_screen.dart';
import '../ui/home/main_screen.dart';
import '../ui/places/place_detail_screen.dart';
import '../ui/places/places_screen.dart';
import '../ui/wallets/bank_callback_screen.dart';
import '../ui/wallets/wallet_detail_screen.dart';
import '../ui/wallets/wallets_screen.dart';
import 'route_guard.dart';

final Provider<GoRouter> routerProv = Provider<GoRouter>((aRef)
{
  final authState = ValueNotifier<AuthState>(aRef.read(authProv));
  aRef.listen<AuthState>(authProv, (_, aNext) => authState.value = aNext);

  final router = GoRouter(
    initialLocation: homePath,
    refreshListenable: authState,
    redirect: (_, aState) => resolveRedirect(authState.value, aState.uri),
    routes: [
      GoRoute(path: splashPath, builder: (_, __) => const SplashScreen()),
      GoRoute(path: authPath, builder: (_, __) => const AuthScreen()),
      ShellRoute(
        builder: (_, __, aChild) => MainScreen(child: aChild),
        routes: [
          GoRoute(
            path: homePath,
            builder: (_, __) => const DashboardScreen(),
            routes: [
              GoRoute(path: 'families', builder: (_, __) => const FamGroupsScreen()),
              GoRoute(path: 'families/new', builder: (_, __) => const FamDetailScreen()),
              GoRoute(
                path: 'families/:id',
                builder: (_, aState) => FamDetailScreen(famId: aState.pathParameters['id']),
              ),
              GoRoute(path: 'wallets', builder: (_, __) => const WalletsScreen()),
              GoRoute(path: 'wallets/new', builder: (_, __) => const WalletDetailScreen()),
              GoRoute(
                path: 'wallets/:id',
                builder: (_, aState) => WalletDetailScreen(walletId: aState.pathParameters['id']),
              ),
              GoRoute(
                path: 'bank-callback',
                builder: (_, aState) => BankCallbackScreen(
                  code: aState.uri.queryParameters['code'],
                  state: aState.uri.queryParameters['state'],
                  error: aState.uri.queryParameters['error'],
                ),
              ),
              GoRoute(
                path: 'transactions',
                builder: (_, aState) => TransactionsScreen.fromQuery(
                  aState.uri.queryParameters,
                  aKey: ValueKey(aState.uri.query),
                ),
              ),
              GoRoute(path: 'receipts', builder: (_, __) => const ReceiptsScreen()),
              GoRoute(
                path: 'receipts/new',
                builder: (_, aState) => ReceiptDetailScreen(initialTx: aState.extra is TxDto ? aState.extra as TxDto : null),
              ),
              GoRoute(
                path: 'receipts/:id',
                builder: (_, aState) => ReceiptDetailScreen(
                  key: ValueKey(aState.pathParameters['id']),
                  receiptId: aState.pathParameters['id'],
                ),
              ),
              GoRoute(path: 'cities', builder: (_, __) => const CitiesDictScreen()),
              GoRoute(path: 'streets', builder: (_, __) => const StreetsDictScreen()),
              GoRoute(path: 'places', builder: (_, __) => const PlacesScreen()),
              GoRoute(path: 'places/new', builder: (_, __) => const PlaceDetailScreen()),
              GoRoute(
                path: 'places/:id',
                builder: (_, aState) => PlaceDetailScreen(placeId: aState.pathParameters['id']),
              ),
              GoRoute(path: 'items', builder: (_, __) => const ItemsScreen()),
              GoRoute(path: 'items/new', builder: (_, __) => const ItemDetailScreen()),
              GoRoute(
                path: 'items/:id',
                builder: (_, aState) => ItemDetailScreen(
                  key: ValueKey(aState.pathParameters['id']),
                  itemId: aState.pathParameters['id'],
                ),
              ),
              GoRoute(path: 'exercises', builder: (_, __) => const ExercisesScreen()),
              GoRoute(path: 'exercises/new', builder: (_, __) => const ExerciseDetailScreen()),
              GoRoute(
                path: 'exercises/:id',
                builder: (_, aState) => ExerciseDetailScreen(exId: aState.pathParameters['id']),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  aRef.onDispose(()
  {
    router.dispose();
    authState.dispose();
  });

  return router;
});
