import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../ui/auth/auth_screen.dart';
import '../ui/home/main_screen.dart';
import '../ui/home/dashboard_screen.dart';

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
          ),
        ],
      ),
    ],
  );
});