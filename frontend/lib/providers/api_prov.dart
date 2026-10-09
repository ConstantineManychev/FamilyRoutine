import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/api_svc.dart';
import '../core/token_store.dart';
import '../domain/models.dart';
import 'auth_provider.dart';

final Provider<TokenStore> tokenStoreProv = Provider<TokenStore>((aRef) => TokenStore(const FlutterSecureStorage()));

final Provider<ApiSvc> apiProv = Provider<ApiSvc>((aRef)
{
  final api = ApiSvc(Dio(), aRef.watch(tokenStoreProv));
  api.onUnauthorized = () => aRef.read(authProv.notifier).handleUnauthorized();
  return api;
});

final Provider<String?> sessionUserIdProv = Provider<String?>((aRef)
{
  return aRef.watch(authProv.select((aState) => aState.user?.id));
});

final AutoDisposeFutureProvider<List<FamDto>> famsProv = FutureProvider.autoDispose<List<FamDto>>((aRef) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getFams();
});

final AutoDisposeFutureProvider<List<AccountDto>> walletsProv = FutureProvider.autoDispose<List<AccountDto>>((aRef) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getWallets();
});

final AutoDisposeFutureProvider<List<DictMetaDto>> dictsMetaProv =
    FutureProvider.autoDispose<List<DictMetaDto>>((aRef) async
{
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return const [];
  }
  return aRef.read(apiProv).getDictsMeta();
});
