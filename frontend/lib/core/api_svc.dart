import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ApiSvc {
  final Dio _dio;
  final FlutterSecureStorage _storage;

  ApiSvc(this._dio, this._storage) {
    _dio.options.baseUrl = const String.fromEnvironment('API_URL', defaultValue: 'http://127.0.0.1:3000');
    
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (opts, hnd) async {
        final tkn = await _storage.read(key: 'jwt');
        if (tkn != null) {
          opts.headers['Authorization'] = 'Bearer $tkn';
        }
        return hnd.next(opts);
      },
      onResponse: (res, hnd) async {
        final tkn = res.headers.value('x-auth-token');
        if (tkn != null) {
          await _storage.write(key: 'jwt', value: tkn);
        }
        return hnd.next(res);
      },
      onError: (err, hnd) async {
        if (err.response?.statusCode == 401) {
          await _storage.delete(key: 'jwt');
        }
        return hnd.next(err);
      },
    ));
  }

  Future<Response> get(String path) => _dio.get(path);
  Future<Response> post(String path, {dynamic data}) => _dio.post(path, data: data);
}