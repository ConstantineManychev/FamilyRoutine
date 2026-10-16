import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models.dart';
import '../providers/auth_provider.dart';
import '../ui/auth/auth_screen.dart';
import '../ui/auth/splash_screen.dart';
import '../ui/common/page_frames.dart';
import '../ui/dicts/cities_dict_screen.dart';
import '../ui/dicts/exercise_detail_screen.dart';
import '../ui/dicts/exercises_screen.dart';
import '../ui/dicts/item_detail_screen.dart';
import '../ui/dicts/items_screen.dart';
import '../ui/dicts/product_cats_screen.dart';
import '../ui/dicts/streets_dict_screen.dart';
import '../ui/finance/receipt_detail_screen.dart';
import '../ui/finance/receipts_screen.dart';
import '../ui/finance/transactions_screen.dart';
import '../ui/home/app_frame.dart';
import '../ui/home/fam_detail_screen.dart';
import '../ui/home/fam_groups_screen.dart';
import '../ui/home/home_screen.dart';
import '../ui/nutrition/add_food_screen.dart';
import '../ui/nutrition/dish_editor_screen.dart';
import '../ui/nutrition/dishes_screen.dart';
import '../ui/nutrition/nutrition_diary_screen.dart';
import '../ui/nutrition/nutrition_format.dart';
import '../ui/places/place_detail_screen.dart';
import '../ui/places/places_screen.dart';
import '../ui/planner/plan_event_editor_screen.dart';
import '../ui/planner/planner_screen.dart';
import '../ui/profile/metric_history_screen.dart';
import '../ui/profile/profile_screen.dart';
import '../ui/settings/settings_screen.dart';
import '../ui/training/exercise_progress_screen.dart';
import '../ui/training/person_session_screen.dart';
import '../ui/training/program_editor_screen.dart';
import '../ui/training/training_screen.dart';
import '../ui/training/workout_session_screen.dart';
import '../ui/wallets/bank_callback_screen.dart';
import '../ui/wallets/banks_screen.dart';
import '../ui/wallets/wallet_detail_screen.dart';
import '../ui/wallets/wallets_screen.dart';
import 'route_guard.dart';

GoRoute _sub(String aPath, Widget Function(GoRouterState aState) aBuild, {List<RouteBase> aRoutes = const []})
{
  return GoRoute(path: aPath, builder: (_, aState) => SubPage(child: aBuild(aState)), routes: aRoutes);
}

GoRoute _own(String aPath, Widget Function(GoRouterState aState) aBuild)
{
  return GoRoute(path: aPath, builder: (_, aState) => aBuild(aState));
}

String? _param(GoRouterState aState, String aName) => aState.pathParameters[aName];

final Provider<GoRouter> routerProv = Provider<GoRouter>((aRef)
{
  final authState = ValueNotifier<AuthState>(aRef.read(authProv));
  aRef.listen<AuthState>(authProv, (_, aNext) => authState.value = aNext);
  GoRouter.optionURLReflectsImperativeAPIs = true;

  final router = GoRouter(
    initialLocation: homePath,
    refreshListenable: authState,
    redirect: (_, aState) => resolveRedirect(authState.value, aState.uri),
    routes: [
      GoRoute(path: splashPath, builder: (_, __) => const SplashScreen()),
      GoRoute(path: authPath, builder: (_, __) => const AuthScreen()),
      ShellRoute(
        builder: (_, __, aChild) => AppFrame(child: aChild),
        routes: [
          GoRoute(
            path: homePath,
            builder: (_, aState) => HomeScreen(initialTab: aState.uri.queryParameters['tab']),
            routes: [
              _own('families', (_) => const FamGroupsScreen()),
              _sub('families/new', (_) => const FamDetailScreen()),
              _sub('families/:id', (aState) => FamDetailScreen(famId: _param(aState, 'id'))),
              _own('wallets', (_) => const WalletsScreen()),
              _sub('wallets/new', (_) => const WalletDetailScreen()),
              _sub('wallets/:id', (aState) => WalletDetailScreen(walletId: _param(aState, 'id'))),
              _own('banks', (_) => const BanksScreen()),
              _sub(
                'bank-callback',
                (aState) => BankCallbackScreen(
                  code: aState.uri.queryParameters['code'],
                  state: aState.uri.queryParameters['state'],
                  error: aState.uri.queryParameters['error'],
                ),
              ),
              _own('transactions', (aState) => TransactionsScreen.fromQuery(aState.uri.queryParameters, aKey: ValueKey(aState.uri.query))),
              _own('receipts', (_) => const ReceiptsScreen()),
              _sub(
                'receipts/new',
                (aState) => ReceiptDetailScreen(
                  initialTx: aState.extra is TxDto ? aState.extra as TxDto : null,
                  prefill: aState.extra is ReceiptPrefill ? aState.extra as ReceiptPrefill : null,
                ),
              ),
              _sub('receipts/:id', (aState) => ReceiptDetailScreen(key: ValueKey(_param(aState, 'id')), receiptId: _param(aState, 'id'))),
              _own('cities', (_) => const CitiesDictScreen()),
              _own('streets', (_) => const StreetsDictScreen()),
              _own('places', (_) => const PlacesScreen()),
              _sub('places/new', (_) => const PlaceDetailScreen()),
              _sub('places/:id', (aState) => PlaceDetailScreen(placeId: _param(aState, 'id'))),
              _own('items', (_) => const ItemsScreen()),
              _sub('items/new', (aState) => ItemDetailScreen(initialBarcode: aState.uri.queryParameters['barcode'])),
              _sub('items/:id', (aState) => ItemDetailScreen(key: ValueKey(_param(aState, 'id')), itemId: _param(aState, 'id'))),
              _sub('settings', (_) => const SettingsScreen()),
              _own('planner', (_) => const PlannerScreen()),
              _sub(
                'planner/events/new',
                (aState) => PlanEventEditorScreen(initialDate: DateTime.tryParse(aState.uri.queryParameters['date'] ?? '')),
              ),
              _sub('planner/events/:id', (aState) => PlanEventEditorScreen(key: ValueKey(_param(aState, 'id')), eventId: _param(aState, 'id'))),
              _sub(
                'training',
                (_) => const TrainingScreen(),
                aRoutes: [
                  _sub('programs/new', (_) => const ProgramEditorScreen()),
                  _sub('programs/:id', (aState) => ProgramEditorScreen(key: ValueKey(_param(aState, 'id')), programId: _param(aState, 'id'))),
                  _sub('sessions/:id', (aState) => WorkoutSessionScreen(key: ValueKey(_param(aState, 'id')), sessionId: _param(aState, 'id')!)),
                  _sub('exercises/:id', (aState) => ExerciseProgressScreen(key: ValueKey(_param(aState, 'id')), exId: _param(aState, 'id')!)),
                ],
              ),
              _sub('profile', (_) => const ProfileScreen()),
              _sub('people/:id', (aState) => ProfileScreen(key: ValueKey(_param(aState, 'id')), personId: _param(aState, 'id'))),
              _sub(
                'people/:id/sessions/:sid',
                (aState) => PersonSessionScreen(
                  key: ValueKey(aState.uri.path),
                  personId: _param(aState, 'id')!,
                  sessionId: _param(aState, 'sid')!,
                ),
              ),
              _sub(
                'people/:id/exercises/:ex',
                (aState) => ExerciseProgressScreen(
                  key: ValueKey(aState.uri.path),
                  exId: _param(aState, 'ex')!,
                  personId: _param(aState, 'id'),
                ),
              ),
              _sub(
                'people/:id/metrics/:metric',
                (aState) => MetricHistoryScreen(
                  key: ValueKey(aState.uri.path),
                  personId: _param(aState, 'id')!,
                  metric: BodyMetric.parse(_param(aState, 'metric')) ?? BodyMetric.weight,
                ),
              ),
              _own('nutrition', (aState) => NutritionDiaryScreen(initialDate: DateTime.tryParse(aState.uri.queryParameters['date'] ?? ''))),
              _own(
                'nutrition/add',
                (aState) => AddFoodScreen(
                  key: ValueKey(aState.uri.toString()),
                  date: dayOnly(DateTime.tryParse(aState.uri.queryParameters['date'] ?? '') ?? DateTime.now()),
                  meal: aState.uri.queryParameters['meal'] == null
                      ? MealSlot.forHour(DateTime.now().hour)
                      : MealSlot.parse(aState.uri.queryParameters['meal']),
                  markId: aState.uri.queryParameters['mark'],
                ),
              ),
              _own('product-cats', (_) => const ProductCatsScreen()),
              _own('product-cats/:id', (aState) => ProductCatScreen(key: ValueKey(_param(aState, 'id')), catId: _param(aState, 'id')!)),
              _own('dishes', (_) => const DishesScreen()),
              _own('dishes/new', (_) => const DishEditorScreen()),
              _own('dishes/:id', (aState) => DishEditorScreen(key: ValueKey(_param(aState, 'id')), dishId: _param(aState, 'id'))),
              _own('exercises', (_) => const ExercisesScreen()),
              _sub('exercises/new', (_) => const ExerciseDetailScreen()),
              _sub('exercises/:id', (aState) => ExerciseDetailScreen(exId: _param(aState, 'id'))),
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
