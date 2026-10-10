import 'package:dio/dio.dart';

import '../domain/models.dart';
import 'app_config.dart';
import 'token_store.dart';

typedef UnauthorizedHandler = void Function();

class ApiSvc
{
  final Dio _dio;
  final TokenStore _tokens;
  UnauthorizedHandler? onUnauthorized;

  ApiSvc(this._dio, this._tokens)
  {
    _dio.options
      ..baseUrl = AppConfig.apiBaseUrl
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 30)
      ..headers[AppConfig.csrfHeader] = AppConfig.csrfValue
      ..extra['withCredentials'] = AppConfig.isCookieMode;

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (aOptions, aHandler) async
      {
        final token = await _tokens.read();
        if (token != null)
        {
          aOptions.headers['Authorization'] = 'Bearer $token';
        }
        aHandler.next(aOptions);
      },
      onError: (aError, aHandler)
      {
        final isAuthCall = aError.requestOptions.path.startsWith('/api/auth/');
        if (aError.response?.statusCode == 401 && !isAuthCall)
        {
          onUnauthorized?.call();
        }
        aHandler.next(aError);
      },
    ));
  }

  List<T> _list<T>(Object? aData, T Function(Map<String, dynamic>) aParse)
  {
    return (aData as List).map((aItem) => aParse(aItem as Map<String, dynamic>)).toList();
  }

  Future<bool> hasStoredToken() async => await _tokens.read() != null;

  Future<void> clearToken() => _tokens.clear();

  Future<void> purgeLegacyTokens() => _tokens.purgeLegacy();

  Future<UserProf> login(String aEmail, String aPassword) async
  {
    final res = await _dio.post('/api/auth/login', data: {
      'email': aEmail,
      'password': aPassword,
      'is_cookie_mode': AppConfig.isCookieMode,
    });

    final token = res.data['token'] as String?;
    if (token != null)
    {
      await _tokens.write(token);
    }

    return UserProf.fromJson(res.data['user'] as Map<String, dynamic>);
  }

  Future<void> register(RegisterData aData) async
  {
    await _dio.post('/api/auth/register', data: aData.toJson());
  }

  Future<void> logout() async
  {
    try
    {
      await _dio.post('/api/auth/logout');
    }
    on DioException
    {
      return;
    }
    finally
    {
      await _tokens.clear();
    }
  }

  Future<UserProf> getMe() async
  {
    final res = await _dio.get('/api/user/me');
    return UserProf.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<DictMetaDto>> getDictsMeta() async
  {
    final res = await _dio.get('/api/dicts');
    return _list(res.data, DictMetaDto.fromJson);
  }

  Future<List<FamDto>> getFams() async
  {
    final res = await _dio.get('/api/families');
    return _list(res.data, FamDto.fromJson);
  }

  Future<FamDetailDto> createFam(String aName) async
  {
    final res = await _dio.post('/api/families', data: {'name': aName});
    return FamDetailDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<FamDetailDto> getFamDetails(String aFamId) async
  {
    final res = await _dio.get('/api/families/$aFamId');
    return FamDetailDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> renameFam(String aFamId, String aName) => _dio.put('/api/families/$aFamId', data: {'name': aName});

  Future<void> deleteFam(String aFamId) => _dio.delete('/api/families/$aFamId');

  Future<void> leaveFam(String aFamId) => _dio.post('/api/families/$aFamId/leave');

  Future<void> updateMemberRole(String aFamId, String aUserId, MemberRole aRole) =>
      _dio.put('/api/families/$aFamId/members/$aUserId', data: {'role': aRole.toJson()});

  Future<void> removeMember(String aFamId, String aUserId) => _dio.delete('/api/families/$aFamId/members/$aUserId');

  Future<void> transferOwnership(String aFamId, String aUserId) =>
      _dio.post('/api/families/$aFamId/transfer', data: {'user_id': aUserId});

  Future<CreatedInviteDto> createInvite(String aFamId, MemberRole aRole, String? aLabel) async
  {
    final res = await _dio.post('/api/families/$aFamId/invites', data: {
      'role': aRole.toJson(),
      'label': aLabel,
    });
    return CreatedInviteDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<FamInviteDto>> getFamInvites(String aFamId) async
  {
    final res = await _dio.get('/api/families/$aFamId/invites');
    return _list(res.data, FamInviteDto.fromJson);
  }

  Future<void> revokeInvite(String aFamId, String aInviteId) =>
      _dio.delete('/api/families/$aFamId/invites/$aInviteId');

  Future<String> acceptInvite(String aCode) async
  {
    final res = await _dio.post('/api/invites/accept', data: {'code': aCode});
    return res.data['family_id'] as String;
  }

  Future<List<AccountDto>> getWallets() async
  {
    final res = await _dio.get('/api/wallets');
    return _list(res.data, AccountDto.fromJson);
  }

  Future<AccountDto> getWallet(String aId) async
  {
    final res = await _dio.get('/api/wallets/$aId');
    return AccountDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AccountDto> createWallet(Map<String, dynamic> aPayload) async
  {
    final res = await _dio.post('/api/wallets', data: aPayload);
    return AccountDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AccountDto> updateWallet(String aId, Map<String, dynamic> aPayload) async
  {
    final res = await _dio.put('/api/wallets/$aId', data: aPayload);
    return AccountDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> archiveWallet(String aId, bool aIsActive) =>
      _dio.put('/api/wallets/$aId/archive', data: {'is_active': aIsActive});

  Future<void> deleteWallet(String aId) => _dio.delete('/api/wallets/$aId');

  Future<List<CurrencyDto>> getCurrencies() async
  {
    final res = await _dio.get('/api/currencies');
    return _list(res.data, CurrencyDto.fromJson);
  }

  Future<List<CountryDto>> getCountries() async
  {
    final res = await _dio.get('/api/geo/countries');
    return _list(res.data, CountryDto.fromJson);
  }

  Future<List<CityDto>> getCities(String aCountryId) async
  {
    final res = await _dio.get('/api/geo/countries/$aCountryId/cities');
    return _list(res.data, CityDto.fromJson);
  }

  Future<CityDto> createCity(String aCountryId, String aName) async
  {
    final res = await _dio.post('/api/geo/countries/$aCountryId/cities', data: {'name': aName});
    return CityDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CityDto> updateCity(String aId, String aName) async
  {
    final res = await _dio.put('/api/geo/cities/$aId', data: {'name': aName});
    return CityDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteCity(String aId) => _dio.delete('/api/geo/cities/$aId');

  Future<List<StreetDto>> getStreets(String aCityId) async
  {
    final res = await _dio.get('/api/geo/cities/$aCityId/streets');
    return _list(res.data, StreetDto.fromJson);
  }

  Future<StreetDto> createStreet(String aCityId, String aName) async
  {
    final res = await _dio.post('/api/geo/cities/$aCityId/streets', data: {'name': aName});
    return StreetDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StreetDto> updateStreet(String aId, String aName) async
  {
    final res = await _dio.put('/api/geo/streets/$aId', data: {'name': aName});
    return StreetDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteStreet(String aId) => _dio.delete('/api/geo/streets/$aId');

  Future<List<PlaceDto>> getPlaces() async
  {
    final res = await _dio.get('/api/places');
    return _list(res.data, PlaceDto.fromJson);
  }

  Future<PlaceDto> getPlace(String aId) async
  {
    final res = await _dio.get('/api/places/$aId');
    return PlaceDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PlaceDto> createPlace(String aName, List<PlaceAddrDto> aAddrs) async
  {
    final res = await _dio.post('/api/places', data: _placePayload(aName, aAddrs));
    return PlaceDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PlaceDto> updatePlace(String aId, String aName, List<PlaceAddrDto> aAddrs) async
  {
    final res = await _dio.put('/api/places/$aId', data: _placePayload(aName, aAddrs));
    return PlaceDto.fromJson(res.data as Map<String, dynamic>);
  }

  Map<String, dynamic> _placePayload(String aName, List<PlaceAddrDto> aAddrs) => {
        'name': aName,
        'addrs': aAddrs.map((aAddr) => aAddr.toJson()).toList(),
      };

  Future<void> deletePlace(String aId) => _dio.delete('/api/places/$aId');

  Future<List<DictExDto>> getExercises() async
  {
    final res = await _dio.get('/api/dicts/exercises');
    return _list(res.data, DictExDto.fromJson);
  }

  Future<DictExDto> getExercise(String aId) async
  {
    final res = await _dio.get('/api/dicts/exercises/$aId');
    return DictExDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<DictExDto> createExercise(Map<String, dynamic> aPayload) async
  {
    final res = await _dio.post('/api/dicts/exercises', data: aPayload);
    return DictExDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<DictExDto> updateExercise(String aId, Map<String, dynamic> aPayload) async
  {
    final res = await _dio.put('/api/dicts/exercises/$aId', data: aPayload);
    return DictExDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteExercise(String aId) => _dio.delete('/api/dicts/exercises/$aId');

  Future<List<BankConnDto>> getBankConns() async
  {
    final res = await _dio.get('/api/banks/connections');
    return _list(res.data, BankConnDto.fromJson);
  }

  Future<BankConnDto> connectMonobank(String aToken) async
  {
    final res = await _dio.post('/api/banks/monobank', data: {'token': aToken});
    return BankConnDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<AspspDto>> getAspsps(String aCountry) async
  {
    final res = await _dio.get('/api/banks/enable-banking/aspsps', queryParameters: {'country': aCountry});
    return _list(res.data, AspspDto.fromJson);
  }

  Future<String> startBankAuth(String aAspspName, String aCountry) async
  {
    final res = await _dio.post('/api/banks/enable-banking/start', data: {
      'aspsp_name': aAspspName,
      'aspsp_country': aCountry,
    });
    return res.data['url'] as String;
  }

  Future<BankConnDto> completeBankAuth(String aCode, String aState) async
  {
    final res = await _dio.post('/api/banks/enable-banking/complete', data: {'code': aCode, 'state': aState});
    return BankConnDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> requestBankSync(String aConnId) => _dio.post('/api/banks/connections/$aConnId/sync');

  Future<void> deleteBankConn(String aConnId) => _dio.delete('/api/banks/connections/$aConnId');

  Future<TxPage> getTransactions({
    String? aAccountId,
    DateTime? aFrom,
    DateTime? aTo,
    String? aCursor,
    int aLimit = 50,
    bool aIsUnlinked = false,
    String? aQuery,
  }) async
  {
    final res = await _dio.get('/api/transactions', queryParameters: {
      if (aAccountId != null) 'account_id': aAccountId,
      if (aFrom != null) 'from': aFrom.toUtc().toIso8601String(),
      if (aTo != null) 'to': aTo.toUtc().toIso8601String(),
      if (aCursor != null) 'cursor': aCursor,
      'limit': aLimit,
      if (aIsUnlinked) 'is_unlinked': true,
      if (aQuery != null && aQuery.trim().isNotEmpty) 'q': aQuery.trim(),
    });
    return TxPage.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TxDto> createTransaction(String aAccountId, double aAmount, DateTime aTs, String? aNote) async
  {
    final res = await _dio.post('/api/transactions', data: {
      'account_id': aAccountId,
      'amount': moneyWire(aAmount),
      'tx_ts': aTs.toUtc().toIso8601String(),
      'note': aNote,
    });
    return TxDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TxDto> updateTransaction(String aId, String? aNote, TxCategory? aCategory) async
  {
    final res = await _dio.put('/api/transactions/$aId', data: {'note': aNote, 'category': aCategory?.name});
    return TxDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteTransaction(String aId) => _dio.delete('/api/transactions/$aId');

  Future<void> createTransfer({
    required String aFromAccountId,
    required String aToAccountId,
    required DateTime aTs,
    double? aAmount,
    double? aToAmount,
    String? aFromTxId,
    String? aNote,
  }) async
  {
    await _dio.post('/api/transfers', data: {
      'from_account_id': aFromAccountId,
      'to_account_id': aToAccountId,
      'tx_ts': aTs.toUtc().toIso8601String(),
      'amount': aAmount == null ? null : moneyWire(aAmount),
      'to_amount': aToAmount == null ? null : moneyWire(aToAmount),
      'from_tx_id': aFromTxId,
      'note': aNote,
    });
  }

  Future<void> deleteTransfer(String aTransferId) => _dio.delete('/api/transfers/$aTransferId');

  Future<List<MerchantDto>> getMerchants(String aQuery) async
  {
    final res = await _dio.get('/api/merchants', queryParameters: {'q': aQuery});
    return _list(res.data, MerchantDto.fromJson);
  }

  Future<List<ReceiptListItem>> getReceipts() async
  {
    final res = await _dio.get('/api/receipts');
    return _list(res.data, ReceiptListItem.fromJson);
  }

  Future<ReceiptDto> getReceipt(String aId) async
  {
    final res = await _dio.get('/api/receipts/$aId');
    return ReceiptDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ReceiptDto> saveReceipt(String? aId, Map<String, dynamic> aPayload) async
  {
    final res = aId == null
        ? await _dio.post('/api/receipts', data: aPayload)
        : await _dio.put('/api/receipts/$aId', data: aPayload);
    return ReceiptDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteReceipt(String aId) => _dio.delete('/api/receipts/$aId');

  Future<List<CashflowSeries>> getCashflow({
    required DateTime aFrom,
    required DateTime aTo,
    required StatsBucket aBucket,
    String? aAccountId,
  }) async
  {
    final res = await _dio.get('/api/stats/cashflow', queryParameters: {
      'from': aFrom.toUtc().toIso8601String(),
      'to': aTo.toUtc().toIso8601String(),
      'bucket': aBucket.name,
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      if (aAccountId != null) 'account_id': aAccountId,
    });
    return _list(res.data['series'], CashflowSeries.fromJson);
  }
}
