import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../domain/models.dart';

class ApiSvc {
  final Dio _dio;
  final FlutterSecureStorage _storage;

  ApiSvc(this._dio, this._storage) {
    _dio.options.baseUrl = const String.fromEnvironment('VITE_API_URL', defaultValue: 'http://127.0.0.1:3000');
    
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
  Future<Response> put(String path, {dynamic data}) => _dio.put(path, data: data);
  Future<Response> delete(String path) => _dio.delete(path);

  Future<List<DictMetaDto>> getDictsMeta() async {
    final res = await _dio.get('/api/dicts');
    return (res.data as List).map((e) => DictMetaDto.fromJson(e)).toList();
  }

  Future<List<FamDto>> getFams() async {
    final res = await _dio.get('/api/families');
    return (res.data as List).map((e) => FamDto.fromJson(e)).toList();
  }

  Future<FamDetailDto> createFam(String name, List<Map<String, String>> members) async {
    final res = await _dio.post('/api/families', data: {
      'name': name,
      'members': members,
    });
    return FamDetailDto.fromJson(res.data);
  }

  Future<FamDetailDto> getFamDetails(String id) async {
    final res = await _dio.get('/api/families/$id');
    return FamDetailDto.fromJson(res.data);
  }

  Future<void> deleteFam(String id) async => await _dio.delete('/api/families/$id');
  Future<void> leaveFam(String id) async => await _dio.delete('/api/families/$id/leave');
  Future<void> updateFamName(String id, String name) async => await _dio.put('/api/families/$id', data: {'name': name});
  Future<void> addFamMember(String famId, String email, String role) async => await _dio.post('/api/families/$famId/members', data: {'email': email, 'role': role});
  Future<void> updateFamMemberRole(String famId, String userId, String role) async => await _dio.put('/api/families/$famId/members/$userId', data: {'role': role});
  Future<void> removeFamMember(String famId, String userId) async => await _dio.delete('/api/families/$famId/members/$userId');

  Future<List<AccountDto>> getWallets() async {
    final res = await _dio.get('/api/wallets');
    return (res.data as List).map((e) => AccountDto.fromJson(e)).toList();
  }

  Future<AccountDto> createWallet(Map<String, dynamic> data) async {
    final res = await _dio.post('/api/wallets', data: data);
    return AccountDto.fromJson(res.data);
  }

  Future<AccountDto> updateWallet(String id, Map<String, dynamic> data) async {
    final res = await _dio.put('/api/wallets/$id', data: data);
    return AccountDto.fromJson(res.data);
  }

  Future<void> archiveWallet(String id, bool isActive) async {
    await _dio.put('/api/wallets/$id/archive', data: {'is_active': isActive});
  }

  Future<void> deleteWallet(String id) async {
    await _dio.delete('/api/wallets/$id');
  }

  Future<AccountDto> getWalletDetail(String id) async {
    final res = await _dio.get('/api/wallets/$id');
    return AccountDto.fromJson(res.data);
  }

  Future<List<CurrencyDto>> getCurrencies() async {
    final res = await _dio.get('/api/currencies');
    return (res.data as List).map((e) => CurrencyDto.fromJson(e)).toList();
  }

  Future<List<CountryDto>> getCountries() async {
    final res = await _dio.get('/api/geo/countries');
    return (res.data as List).map((e) => CountryDto.fromJson(e)).toList();
  }

  Future<List<CityDto>> getCities(String countryId) async {
    final res = await _dio.get('/api/geo/countries/$countryId/cities');
    return (res.data as List).map((e) => CityDto.fromJson(e)).toList();
  }

  Future<CityDto> createCity(String countryId, String name) async {
    final res = await _dio.post('/api/geo/countries/$countryId/cities', data: {'name': name});
    return CityDto.fromJson(res.data);
  }

  Future<CityDto> updateCity(String id, String name) async {
    final res = await _dio.put('/api/geo/cities/$id', data: {'name': name});
    return CityDto.fromJson(res.data);
  }

  Future<void> deleteCity(String id) async {
    await _dio.delete('/api/geo/cities/$id');
  }

  Future<List<StreetDto>> getStreets(String cityId) async {
    final res = await _dio.get('/api/geo/cities/$cityId/streets');
    return (res.data as List).map((e) => StreetDto.fromJson(e)).toList();
  }

  Future<StreetDto> createStreet(String cityId, String name) async {
    final res = await _dio.post('/api/geo/cities/$cityId/streets', data: {'name': name});
    return StreetDto.fromJson(res.data);
  }

  Future<StreetDto> updateStreet(String id, String name) async {
    final res = await _dio.put('/api/geo/streets/$id', data: {'name': name});
    return StreetDto.fromJson(res.data);
  }

  Future<void> deleteStreet(String id) async {
    await _dio.delete('/api/geo/streets/$id');
  }

  Future<List<PlaceDto>> getPlaces() async {
    final res = await _dio.get('/api/places');
    return (res.data as List).map((e) => PlaceDto.fromJson(e)).toList();
  }

  Future<PlaceDto> getPlaceDetail(String id) async {
    final res = await _dio.get('/api/places/$id');
    return PlaceDto.fromJson(res.data);
  }

  Future<PlaceDto> createPlace(PlaceDto place) async {
    final res = await _dio.post('/api/places', data: place.toJson());
    return PlaceDto.fromJson(res.data);
  }

  Future<PlaceDto> updatePlace(String id, PlaceDto place) async {
    final res = await _dio.put('/api/places/$id', data: place.toJson());
    return PlaceDto.fromJson(res.data);
  }

  Future<void> deletePlace(String id) async {
    await _dio.delete('/api/places/$id');
  }
}