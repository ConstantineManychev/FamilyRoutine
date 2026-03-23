import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../core/api_svc.dart';
import '../domain/models.dart';

final storageProv = Provider((ref) => const FlutterSecureStorage());

final apiProv = Provider((ref) => ApiSvc(Dio(), ref.read(storageProv)));

final profProv = FutureProvider<UserProf>((ref) async {
  final api = ref.read(apiProv);
  final res = await api.get('/api/user/me');
  return UserProf.fromJson(res.data);
});

final famsProv = FutureProvider<List<FamDto>>((ref) async {
  final api = ref.read(apiProv);
  final res = await api.get('/api/families');
  return (res.data as List).map((e) => FamDto.fromJson(e)).toList();
});