import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../ui/auth/auth_screen.dart';
import '../ui/home/main_screen.dart';
import '../ui/home/dashboard_screen.dart';
import '../ui/home/fam_groups_screen.dart';
import '../ui/home/fam_detail_screen.dart';
import '../ui/wallets/wallets_screen.dart';
import '../ui/wallets/wallet_detail_screen.dart';
import '../ui/dicts/cities_dict_screen.dart';
import '../ui/dicts/streets_dict_screen.dart';
import '../ui/places/places_screen.dart'; 
import '../ui/places/place_detail_screen.dart';
import '../ui/dicts/exercises_screen.dart';
import '../ui/dicts/exercise_detail_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final isAuth = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/app',
    redirect: (context, state) {
      final loggingIn = state.matchedLocation == '/auth';

      if (!isAuth && !loggingIn) return '/auth';
      if (isAuth && loggingIn) return '/app';
      
      return null;
    },
    routes: [
      GoRoute(
        path: '/auth',
        builder: (context, state) => const AuthScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => MainScreen(child: child),
        routes: [
          GoRoute(
            path: '/app',
            builder: (context, state) => const DashboardScreen(),
            routes: [
              GoRoute(
                path: 'families',
                builder: (context, state) => const FamGroupsScreen(),
              ),
              GoRoute(
                path: 'families/new',
                builder: (context, state) => FamDetailScreen(
                  onSaved: () => context.go('/app/families'),
                ),
              ),
              GoRoute(
                path: 'families/:id',
                builder: (context, state) => FamDetailScreen(
                  famId: state.pathParameters['id'],
                  onSaved: () => context.go('/app/families'),
                ),
              ),
              GoRoute(
                path: 'wallets',
                builder: (context, state) => const WalletsScreen(),
              ),
              GoRoute(
                path: 'wallets/new',
                builder: (context, state) => WalletDetailScreen(
                  onSaved: () => context.go('/app/wallets'),
                ),
              ),
              GoRoute(
                path: 'wallets/:id',
                builder: (context, state) => WalletDetailScreen(
                  walletId: state.pathParameters['id'],
                  onSaved: () => context.go('/app/wallets'),
                ),
              ),
              GoRoute(
                path: 'cities',
                builder: (context, state) => const CitiesDictScreen(),
              ),
              GoRoute(
                path: 'streets',
                builder: (context, state) => const StreetsDictScreen(),
              ),
              GoRoute(
                path: 'places',
                builder: (context, state) => const PlacesScreen(),
              ),
              GoRoute(
                path: 'places/new',
                builder: (context, state) => PlaceDetailScreen(
                  onSaved: () => context.go('/app/places'),
                ),
              ),
              GoRoute(
                path: 'places/:id',
                builder: (context, state) => PlaceDetailScreen(
                  placeId: state.pathParameters['id'],
                  onSaved: () => context.go('/app/places'),
                ),
              ),
              GoRoute(
                path: 'exercises',
                builder: (context, state) => const ExercisesScreen(),
              ),
              GoRoute(
                path: 'exercises/new',
                builder: (context, state) => ExerciseDetailScreen(
                  onSaved: () => context.go('/app/exercises'),
                ),
              ),
              GoRoute(
                path: 'exercises/:id',
                builder: (context, state) => ExerciseDetailScreen(
                  exId: state.pathParameters['id'],
                  onSaved: () => context.go('/app/exercises'),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});