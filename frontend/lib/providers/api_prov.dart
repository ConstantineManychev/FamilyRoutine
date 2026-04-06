import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/api_svc.dart';
import '../domain/models.dart';

final Provider<FlutterSecureStorage> storageProv = Provider((ref) => const FlutterSecureStorage());

final StateProvider<bool> isAuthProv = StateProvider<bool>((ref) => true);

final Provider<ApiSvc> apiProv = Provider<ApiSvc>((ref) {
  final storage = ref.read(storageProv);
  final dio = Dio();

  dio.interceptors.add(InterceptorsWrapper(
    onError: (DioException e, handler) async {
      if (e.response?.statusCode == 401) {
        await storage.delete(key: 'auth_token');
        ref.read(isAuthProv.notifier).state = false;
        ref.invalidate(profProv);
      }
      return handler.next(e);
    },
  ));

  return ApiSvc(dio, storage);
});

final FutureProvider<UserProf> profProv = FutureProvider<UserProf>((ref) async {
  final api = ref.read(apiProv);
  final res = await api.get('/api/user/me');
  return UserProf.fromJson(res.data);
});

final FutureProvider<List<FamDto>> famsProv = FutureProvider<List<FamDto>>((ref) async {
  final api = ref.read(apiProv);
  final res = await api.get('/api/families');
  return (res.data as List).map((e) => FamDto.fromJson(e)).toList();
});

final AutoDisposeFutureProvider<List<AccountDto>> walletsProv = FutureProvider.autoDispose<List<AccountDto>>((ref) async {
  return ref.watch(apiProv).getWallets();
});