import 'package:dio/dio.dart';

import '../domain/models.dart';
import 'app_config.dart';
import 'device_tz.dart';
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

  Future<PlaceDto> createPlace(String aName, List<PlaceAddrDto> aAddrs, {String? aFamilyId}) async
  {
    final res = await _dio.post('/api/places', data: {
      ..._placePayload(aName, aAddrs),
      if (aFamilyId != null) 'family_id': aFamilyId,
    });
    return PlaceDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PlaceDto> sharePlace(String aId, String aFamilyId) async
  {
    final res = await _dio.put('/api/places/$aId/family', data: {'family_id': aFamilyId});
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

  Future<void> linkMerchant(String aMerchantId, String aPlaceId, {String? aPlaceAddrId}) => _dio.put(
        '/api/merchants/$aMerchantId/place',
        data: {'place_id': aPlaceId, 'place_addr_id': aPlaceAddrId},
      );

  Future<void> unlinkMerchant(String aMerchantId) => _dio.delete('/api/merchants/$aMerchantId/place');

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
    TxCategory? aCategory,
    bool aIsUncategorized = false,
    String? aOwnerId,
    String? aConvertTo,
  }) async
  {
    final res = await _dio.get('/api/transactions', queryParameters: {
      if (aConvertTo != null) 'convert_to': aConvertTo,
      if (aOwnerId != null) 'owner_id': aOwnerId,
      if (aCategory != null) 'category': aCategory.name,
      if (aIsUncategorized) 'is_uncategorized': true,
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

  Future<TxDto> updateTransaction(String aId, String? aNote, TxCategory? aCategory, {bool aIsApplyToSimilar = false}) async
  {
    final res = await _dio.put('/api/transactions/$aId', data: {
      'note': aNote,
      'category': aCategory?.name,
      'is_apply_to_similar': aIsApplyToSimilar,
    });
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
    String? aToTxId,
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
      'to_tx_id': aToTxId,
      'note': aNote,
    });
  }

  Future<void> deleteTransfer(String aTransferId) => _dio.delete('/api/transfers/$aTransferId');

  Future<List<DictItemDto>> getItems({
    String? aQuery,
    int? aLimit,
    String? aBarcode,
    bool aIsMine = false,
    ItemKind? aKind,
    String? aCatId,
  }) async
  {
    final res = await _dio.get('/api/dicts/items', queryParameters: {
      if (aQuery != null && aQuery.trim().isNotEmpty) 'q': aQuery.trim(),
      if (aLimit != null) 'limit': aLimit,
      if (aBarcode != null) 'barcode': aBarcode,
      if (aIsMine) 'is_mine': true,
      if (aKind != null) 'kind': aKind.name,
      if (aCatId != null) 'cat_id': aCatId,
    });
    return _list(res.data, DictItemDto.fromJson);
  }

  Future<ProductCatTree> getProductCats() async
  {
    final res = await _dio.get('/api/dicts/product-cats');
    return ProductCatTree.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ProductCat> saveProductCat(String? aId, String aName, String? aParentId) async
  {
    final data = {'name': aName, 'parent_id': aParentId};
    final res = aId == null
        ? await _dio.post('/api/dicts/product-cats', data: data)
        : await _dio.put('/api/dicts/product-cats/$aId', data: data);
    return ProductCat.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteProductCat(String aId) => _dio.delete('/api/dicts/product-cats/$aId');

  Future<ProductCat> mergeProductCat(String aId, String aTargetId) async
  {
    final res = await _dio.post('/api/dicts/product-cats/$aId/merge', data: {'target_id': aTargetId});
    return ProductCat.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CatPrices> getCatPrices(String aId, {String? aConvertTo, int? aDays, String? aPlaceId}) async
  {
    final res = await _dio.get('/api/dicts/product-cats/$aId/prices', queryParameters: {
      if (aConvertTo != null) 'convert_to': aConvertTo,
      if (aDays != null) 'days': aDays,
      if (aPlaceId != null) 'place_id': aPlaceId,
    });
    return CatPrices.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ProductLookup> lookupProduct(String aBarcode, String aLang) async
  {
    final res = await _dio.get('/api/dicts/products/lookup/$aBarcode', queryParameters: {'lang': aLang});
    return ProductLookup.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ProductInfo> recognizeLabel(String aImageBase64, String aMediaType) async
  {
    final res = await _dio.post(
      '/api/dicts/products/label',
      data: {'image': aImageBase64, 'media_type': aMediaType},
      options: Options(receiveTimeout: const Duration(seconds: 150), sendTimeout: const Duration(seconds: 60)),
    );
    return ProductInfo.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<PricePoint>> getPriceHistory(String aItemId, {int aLimit = 30}) async
  {
    final res = await _dio.get('/api/dicts/items/$aItemId/price-history', queryParameters: {'limit': aLimit});
    return _list(res.data, PricePoint.fromJson);
  }

  Future<PricePoint?> getLastPrice(String aItemId, {String? aPlaceId, String? aCurrId}) async
  {
    final res = await _dio.get('/api/dicts/items/$aItemId/last-price', queryParameters: {
      if (aPlaceId != null) 'place_id': aPlaceId,
      if (aCurrId != null) 'curr_id': aCurrId,
    });
    return res.data is Map<String, dynamic> ? PricePoint.fromJson(res.data as Map<String, dynamic>) : null;
  }

  Future<DictItemDto> getItem(String aId) async
  {
    final res = await _dio.get('/api/dicts/items/$aId');
    return DictItemDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<DictItemDto> saveItem(String? aId, Map<String, dynamic> aPayload) async
  {
    final res = aId == null
        ? await _dio.post('/api/dicts/items', data: aPayload)
        : await _dio.put('/api/dicts/items/$aId', data: aPayload);
    return DictItemDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteItem(String aId) => _dio.delete('/api/dicts/items/$aId');

  Future<DictItemDto> fillItem(String aId, Map<String, dynamic> aPayload) async
  {
    final res = await _dio.patch('/api/dicts/items/$aId/fill', data: aPayload);
    return DictItemDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<Dish>> getDishes({String? aQuery}) async
  {
    final res = await _dio.get('/api/dishes', queryParameters: {
      if (aQuery != null && aQuery.trim().isNotEmpty) 'q': aQuery.trim(),
    });
    return _list(res.data, Dish.fromJson);
  }

  Future<Dish> getDish(String aId) async
  {
    final res = await _dio.get('/api/dishes/$aId');
    return Dish.fromJson(res.data as Map<String, dynamic>);
  }

  Future<Dish> saveDish(String? aId, Map<String, dynamic> aPayload) async
  {
    final res = aId == null ? await _dio.post('/api/dishes', data: aPayload) : await _dio.put('/api/dishes/$aId', data: aPayload);
    return Dish.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteDish(String aId) => _dio.delete('/api/dishes/$aId');

  Future<NutritionDay> getNutritionDay(DateTime aDate) async
  {
    final res = await _dio.get('/api/nutrition/day', queryParameters: {
      'date': dateWire(aDate),
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
    });
    return NutritionDay.fromJson(res.data as Map<String, dynamic>);
  }

  Future<MealEntry> addMealEntry(Map<String, dynamic> aPayload) async
  {
    final res = await _dio.post('/api/nutrition/entries', data: aPayload);
    return MealEntry.fromJson(res.data as Map<String, dynamic>);
  }

  Future<MealEntry> updateMealEntry(String aId, Map<String, dynamic> aPayload) async
  {
    final res = await _dio.put('/api/nutrition/entries/$aId', data: aPayload);
    return MealEntry.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteMealEntry(String aId) => _dio.delete('/api/nutrition/entries/$aId');

  Future<List<RecentFood>> getRecentFoods() async
  {
    final res = await _dio.get('/api/nutrition/recent');
    return _list(res.data, RecentFood.fromJson);
  }

  Future<CopyResult> copyMealFromYesterday(String aMarkId, DateTime aDate) async
  {
    final res = await _dio.post('/api/nutrition/copy', data: {'status_mark_id': aMarkId, 'date': dateWire(aDate)});
    return CopyResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StudyTree> getStudyTree() async
  {
    final res = await _dio.get('/api/study/topics');
    return StudyTree.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StudyTopic> createTopic(TopicDraft aDraft) async
  {
    final res = await _dio.post('/api/study/topics', data: aDraft.toJson());
    return StudyTopic.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StudyTopic> updateTopic(String aId, TopicDraft aDraft) async
  {
    final res = await _dio.put('/api/study/topics/$aId', data: aDraft.toJson());
    return StudyTopic.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteTopic(String aId) => _dio.delete('/api/study/topics/$aId');

  Future<List<StudyNote>> getStudyNotes(String aTopicId, {bool aIsBranch = false}) async
  {
    final res = await _dio.get('/api/study/topics/$aTopicId/notes', queryParameters: {'is_branch': aIsBranch});
    return _list(res.data, StudyNote.fromJson);
  }

  Future<StudyNote> createStudyNote(String aTopicId, String aBody, DateTime aNoteTs) async
  {
    final res = await _dio.post(
      '/api/study/topics/$aTopicId/notes',
      data: {'body': aBody.trim(), 'note_ts': aNoteTs.toUtc().toIso8601String()},
    );
    return StudyNote.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StudyNote> updateStudyNote(String aId, String aBody, DateTime aNoteTs) async
  {
    final res = await _dio.put(
      '/api/study/notes/$aId',
      data: {'body': aBody.trim(), 'note_ts': aNoteTs.toUtc().toIso8601String()},
    );
    return StudyNote.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteStudyNote(String aId) => _dio.delete('/api/study/notes/$aId');

  Future<StockSettings> getStockSettings() async
  {
    final res = await _dio.get('/api/stock/settings');
    return StockSettings.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StockSettings> saveStockSettings(String? aFamilyId) async
  {
    final res = await _dio.put('/api/stock/settings', data: {'family_id': aFamilyId});
    return StockSettings.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StockData> getStock({StockStoreRef? aStore}) async
  {
    final res = await _dio.get('/api/stock', queryParameters: aStore?.query);
    return StockData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StockLot> createStockLot({
    required StockStoreRef aStore,
    required String aItemId,
    required double aQty,
    required StockMeasure aUnit,
    double? aCost,
    String? aCurrId,
    DateTime? aAcquiredOn,
    DateTime? aExpiresOn,
  }) async
  {
    final res = await _dio.post('/api/stock/lots', data: {
      ...aStore.query,
      'item_id': aItemId,
      'qty': aQty.toString(),
      'unit': aUnit.name,
      if (aCost != null && aCurrId != null) 'cost': aCost.toStringAsFixed(2),
      if (aCost != null && aCurrId != null) 'curr_id': aCurrId,
      if (aAcquiredOn != null) 'acquired_on': dateWire(aAcquiredOn),
      if (aExpiresOn != null) 'expires_on': dateWire(aExpiresOn),
    });
    return StockLot.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StockLot> setStockLotExpiry(String aId, DateTime? aExpiresOn) async
  {
    final res = await _dio.patch('/api/stock/lots/$aId', data: {'expires_on': aExpiresOn == null ? null : dateWire(aExpiresOn)});
    return StockLot.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteStockLot(String aId) => _dio.delete('/api/stock/lots/$aId');

  Future<StockLot> wasteStockLot(String aId, double aQty, WasteReason aReason, String? aNote) async
  {
    final res = await _dio.post('/api/stock/lots/$aId/waste', data: {
      'qty': aQty.toString(),
      'reason': aReason.name,
      if (aNote != null && aNote.trim().isNotEmpty) 'note': aNote.trim(),
    });
    return StockLot.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CookBatch> cookDish({
    required StockStoreRef aStore,
    required String aDishId,
    required double aCookedG,
    required List<CookIngredient> aIngredients,
    String? aNote,
    DateTime? aExpiresOn,
  }) async
  {
    final res = await _dio.post('/api/stock/cook', data: {
      ...aStore.query,
      'dish_id': aDishId,
      'cooked_g': aCookedG.toString(),
      'ingredients': [
        for (final ingredient in aIngredients) {'item_id': ingredient.itemId, 'grams': ingredient.grams.toString()},
      ],
      if (aNote != null && aNote.trim().isNotEmpty) 'note': aNote.trim(),
      if (aExpiresOn != null) 'expires_on': dateWire(aExpiresOn),
    });
    return CookBatch.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<CookBatch>> getCookBatches(String aDishId) async
  {
    final res = await _dio.get('/api/stock/batches', queryParameters: {'dish_id': aDishId});
    return _list(res.data, CookBatch.fromJson);
  }

  Future<StockMoves> getStockMoves({StockStoreRef? aStore, StockMoveKind? aKind, DateTime? aFrom, DateTime? aTo, int aLimit = 100}) async
  {
    final res = await _dio.get('/api/stock/moves', queryParameters: {
      ...?aStore?.query,
      if (aKind != null) 'kind': aKind.name,
      if (aFrom != null) 'from': aFrom.toUtc().toIso8601String(),
      if (aTo != null) 'to': aTo.toUtc().toIso8601String(),
      'limit': aLimit,
    });
    return StockMoves.fromJson(res.data as Map<String, dynamic>);
  }

  Future<NotifySettings> getNotifySettings() async
  {
    final res = await _dio.get('/api/notifications/settings');
    return NotifySettings.fromJson(res.data as Map<String, dynamic>);
  }

  Future<NotifySettings> saveNotifySettings(Map<String, Object?> aPatch) async
  {
    final res = await _dio.put('/api/notifications/settings', data: aPatch);
    return NotifySettings.fromJson(res.data as Map<String, dynamic>);
  }

  Future<NoticeInbox> getNotices({int aLimit = 50}) async
  {
    final res = await _dio.get('/api/notifications', queryParameters: {'limit': aLimit});
    return NoticeInbox.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> markNoticesRead({List<String> aIds = const [], bool aIsAll = false}) =>
      _dio.post('/api/notifications/read', data: {'ids': aIds, 'is_all': aIsAll});

  Future<String?> getPushKey() async
  {
    final res = await _dio.get('/api/notifications/push-key');
    return (res.data as Map<String, dynamic>)['public_key'] as String?;
  }

  Future<void> addPushSub({required String aEndpoint, required String aP256dh, required String aAuth}) =>
      _dio.post('/api/notifications/push-subs', data: {'endpoint': aEndpoint, 'p256dh': aP256dh, 'auth': aAuth});

  Future<void> removePushSub(String aEndpoint) => _dio.post('/api/notifications/push-subs/remove', data: {'endpoint': aEndpoint});

  Future<List<UpcomingNotice>> getUpcomingNotices({int aHours = 48}) async
  {
    final res = await _dio.get('/api/notifications/upcoming', queryParameters: {'hours': aHours});
    return _list(res.data, UpcomingNotice.fromJson);
  }

  Future<WorkDay> getWorkDay(DateTime aDate) async
  {
    final res = await _dio.get('/api/work/day', queryParameters: {'date': dateWire(aDate)});
    return WorkDay.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TaskDetails> getTask(String aId) async
  {
    final res = await _dio.get('/api/work/tasks/$aId');
    return TaskDetails.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TaskDetails> createTask(TaskDraft aDraft) async
  {
    final res = await _dio.post('/api/work/tasks', data: aDraft.toJson());
    return TaskDetails.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TaskDetails> updateTask(String aId, TaskDraft aDraft) async
  {
    final res = await _dio.put('/api/work/tasks/$aId', data: aDraft.toJson());
    return TaskDetails.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TaskDetails> logTask(String aId, TaskAction aAction, DateTime aDate, {String? aReport, String? aMarkId}) async
  {
    final report = aReport?.trim();
    final res = await _dio.post('/api/work/tasks/$aId/log', data: {
      'action': aAction.name,
      'date': dateWire(aDate),
      if (report != null && report.isNotEmpty) 'report': report,
      if (aMarkId != null) 'status_mark_id': aMarkId,
    });
    return TaskDetails.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> archiveTask(String aId) => _dio.delete('/api/work/tasks/$aId');

  Future<NutritionGoal> getNutritionGoal() async
  {
    final res = await _dio.get('/api/nutrition/goal');
    return NutritionGoal.fromJson(res.data as Map<String, dynamic>);
  }

  Future<NutritionGoal> previewNutritionGoal(GoalDraft aDraft) async
  {
    final res = await _dio.post('/api/nutrition/goal/preview', data: aDraft.toJson());
    return NutritionGoal.fromJson(res.data as Map<String, dynamic>);
  }

  Future<NutritionGoal> saveNutritionGoal(GoalDraft aDraft) async
  {
    final res = await _dio.put('/api/nutrition/goal', data: aDraft.toJson());
    return NutritionGoal.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PersonNorm> getPersonNorm(String aPersonId, DateTime aDate) async
  {
    final res = await _dio.get('/api/people/$aPersonId/nutrition/norm', queryParameters: {
      'date': dateWire(aDate),
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
    });
    return PersonNorm.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ItemPricesData> getItemPrices(String aId, {String? aConvertTo}) async
  {
    final res = await _dio.get('/api/dicts/items/$aId/prices', queryParameters: {
      if (aConvertTo != null) 'convert_to': aConvertTo,
    });
    return ItemPricesData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<DictItemDto> mergeItem(String aId, String aTargetId) async
  {
    final res = await _dio.post('/api/dicts/items/$aId/merge', data: {'target_id': aTargetId});
    return DictItemDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<ManualPriceDto>> getManualPrices(String aItemId) async
  {
    final res = await _dio.get('/api/dicts/items/$aItemId/manual-prices');
    return _list(res.data, ManualPriceDto.fromJson);
  }

  Future<ManualPriceDto> addManualPrice(String aItemId, Map<String, dynamic> aPayload) async
  {
    final res = await _dio.post('/api/dicts/items/$aItemId/manual-prices', data: aPayload);
    return ManualPriceDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteManualPrice(String aItemId, String aPriceId) =>
      _dio.delete('/api/dicts/items/$aItemId/manual-prices/$aPriceId');

  Future<void> setPriceSharing(String aFamId, bool aIsShared) =>
      _dio.put('/api/families/$aFamId/price-sharing', data: {'is_shared': aIsShared});

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

  Future<CashflowData> getCashflow({
    required DateTime aFrom,
    required DateTime aTo,
    required StatsBucket aBucket,
    String? aAccountId,
    String? aOwnerId,
    FlowMode aMode = FlowMode.net,
    String? aConvertTo,
  }) async
  {
    final res = await _dio.get('/api/stats/cashflow', queryParameters: {
      if (aOwnerId != null) 'owner_id': aOwnerId,
      'from': aFrom.toUtc().toIso8601String(),
      'to': aTo.toUtc().toIso8601String(),
      'bucket': aBucket.name,
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      'mode': aMode.name,
      if (aAccountId != null) 'account_id': aAccountId,
      if (aConvertTo != null) 'convert_to': aConvertTo,
    });
    return CashflowData.fromJson(res.data as Map<String, dynamic>);
  }

  Future<CategoryStats> getCategoryStats({
    required DateTime aFrom,
    required DateTime aTo,
    String? aAccountId,
    String? aOwnerId,
    FlowMode aMode = FlowMode.net,
    String? aConvertTo,
  }) async
  {
    final res = await _dio.get('/api/stats/categories', queryParameters: {
      if (aOwnerId != null) 'owner_id': aOwnerId,
      'from': aFrom.toUtc().toIso8601String(),
      'to': aTo.toUtc().toIso8601String(),
      'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
      'mode': aMode.name,
      if (aAccountId != null) 'account_id': aAccountId,
      if (aConvertTo != null) 'convert_to': aConvertTo,
    });
    return CategoryStats.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StatusMarkDto> createMark(RoutineStatus aStatus, {String? aNote, DateTime? aStartTs, DateTime? aEndTs}) async
  {
    final res = await _dio.post('/api/routine/marks', data: {
      'status': aStatus.toJson(),
      if (aNote != null && aNote.trim().isNotEmpty) 'note': aNote.trim(),
      if (aStartTs != null) 'start_ts': aStartTs.toUtc().toIso8601String(),
      if (aEndTs != null) 'end_ts': aEndTs.toUtc().toIso8601String(),
    });
    return StatusMarkDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StatusMarkDto> updateMark(
    String aId,
    RoutineStatus aStatus,
    String? aNote,
    {
      DateTime? aStartTs,
      DateTime? aEndTs,
      bool aIsOpenEnd = false,
    }
  ) async
  {
    final res = await _dio.put('/api/routine/marks/$aId', data: {
      'status': aStatus.toJson(),
      if (aNote != null && aNote.trim().isNotEmpty) 'note': aNote.trim(),
      if (aStartTs != null) 'start_ts': aStartTs.toUtc().toIso8601String(),
      if (aEndTs != null) 'end_ts': aEndTs.toUtc().toIso8601String(),
      if (aIsOpenEnd) 'is_open_end': true,
    });
    return StatusMarkDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<StatusMarkDto?> getCurrentMark() async
  {
    final res = await _dio.get('/api/routine/current');
    final data = res.data;
    return data is Map<String, dynamic> ? StatusMarkDto.fromJson(data) : null;
  }

  Future<MarkDetails> getMarkDetails(String aId) async
  {
    final res = await _dio.get(
      '/api/routine/marks/$aId',
      queryParameters: {'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes},
    );
    return MarkDetails.fromJson(res.data as Map<String, dynamic>);
  }

  Future<MarkDetails> linkMarkMeals(String aId, List<String> aEntryIds) async
  {
    final res = await _dio.put('/api/routine/marks/$aId/meal-entries', data: {'entry_ids': aEntryIds});
    return MarkDetails.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteMark(String aId) => _dio.delete('/api/routine/marks/$aId');

  Future<TimelineDto> getTimeline({String? aFamilyId, required DateTime aFrom, required DateTime aTo}) async
  {
    final res = await _dio.get('/api/routine/timeline', queryParameters: {
      'from': aFrom.toUtc().toIso8601String(),
      'to': aTo.toUtc().toIso8601String(),
      if (aFamilyId != null) 'family_id': aFamilyId,
    });
    return TimelineDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> setRoutineSharing(String aFamId, bool aIsShared) =>
      _dio.put('/api/families/$aFamId/routine-sharing', data: {'is_shared': aIsShared});

  Future<List<DashboardDto>> getDashboards() async
  {
    final res = await _dio.get('/api/dashboards');
    return _list(res.data, DashboardDto.fromJson);
  }

  Future<DashboardDto> createDashboard(String aName, {bool aIsPrefilled = false}) async
  {
    final res = await _dio.post('/api/dashboards', data: {'name': aName, 'is_prefilled': aIsPrefilled});
    return DashboardDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<DashboardDto> renameDashboard(String aId, String aName) async
  {
    final res = await _dio.put('/api/dashboards/$aId', data: {'name': aName});
    return DashboardDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteDashboard(String aId) => _dio.delete('/api/dashboards/$aId');

  Future<DashboardDto> addWidget(String aDashboardId, WidgetKind aKind, {String? aFamilyId}) async
  {
    final res = await _dio.post('/api/dashboards/$aDashboardId/widgets', data: {
      'kind': aKind.wire,
      if (aFamilyId != null) 'family_id': aFamilyId,
    });
    return DashboardDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteWidget(String aDashboardId, String aWidgetId) =>
      _dio.delete('/api/dashboards/$aDashboardId/widgets/$aWidgetId');

  Future<DashboardDto> reorderWidgets(String aDashboardId, List<String> aWidgetIds) async
  {
    final res = await _dio.put('/api/dashboards/$aDashboardId/widgets/order', data: {'widget_ids': aWidgetIds});
    return DashboardDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PersonProfile> getPerson(String aPersonId) async
  {
    final res = await _dio.get('/api/people/$aPersonId');
    return PersonProfile.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PersonProfile> updatePerson(
    String aPersonId,
    {
      required String aFirstName,
      required String aLastName,
      required DateTime aBirthDate,
      Sex? aSex,
      ActivityLevel? aActivity,
    }
  ) async
  {
    final res = await _dio.put('/api/people/$aPersonId', data: {
      'first_name': aFirstName,
      'last_name': aLastName,
      'birth_date': _dateWire(aBirthDate),
      'sex': aSex?.name,
      'activity': aActivity?.wire,
    });
    return PersonProfile.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> changePassword(String aCurrent, String aNew) =>
      _dio.post('/api/user/password', data: {'current_password': aCurrent, 'new_password': aNew});

  Future<List<BodyEntry>> getBodyEntries(String aPersonId, {int aLimit = 100}) async
  {
    final res = await _dio.get('/api/people/$aPersonId/entries', queryParameters: {'limit': aLimit});
    return (res.data as List<dynamic>).map((aItem) => BodyEntry.fromJson(aItem as Map<String, dynamic>)).toList();
  }

  Future<BodyEntry> getBodyEntry(String aPersonId, String aEntryId) async
  {
    final res = await _dio.get('/api/people/$aPersonId/entries/$aEntryId');
    return BodyEntry.fromJson(res.data as Map<String, dynamic>);
  }

  Future<BodyEntry> saveBodyEntry(String aPersonId, String? aEntryId, DateTime aMeasuredTs, String? aNote, List<BodyValue> aValues) async
  {
    final data = {
      'measured_ts': aMeasuredTs.toUtc().toIso8601String(),
      'note': aNote,
      'values': aValues.map((aValue) => aValue.toJson()).toList(),
    };
    final res = aEntryId == null
        ? await _dio.post('/api/people/$aPersonId/entries', data: data)
        : await _dio.put('/api/people/$aPersonId/entries/$aEntryId', data: data);
    return BodyEntry.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteBodyEntry(String aPersonId, String aEntryId) => _dio.delete('/api/people/$aPersonId/entries/$aEntryId');

  Future<List<MetricPoint>> getMetricHistory(String aPersonId, BodyMetric aMetric) async
  {
    final res = await _dio.get('/api/people/$aPersonId/metrics/${aMetric.wire}');
    return (res.data as List<dynamic>).map((aItem) => MetricPoint.fromJson(aItem as Map<String, dynamic>)).toList();
  }

  Future<void> setProfileSharing(String aPersonId, ProfileSharing aSharing) =>
      _dio.put('/api/people/$aPersonId/sharing/${aSharing.familyId}', data: aSharing.toJson());

  Future<PersonProfile> createChild(String aFamId, String aFirstName, String aLastName, DateTime aBirthDate, Sex aSex) async
  {
    final res = await _dio.post('/api/families/$aFamId/children', data: {
      'first_name': aFirstName,
      'last_name': aLastName,
      'birth_date': _dateWire(aBirthDate),
      'sex': aSex.name,
    });
    return PersonProfile.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<ProgramListItem>> getPrograms() async
  {
    final res = await _dio.get('/api/training/programs');
    return (res.data as List<dynamic>).map((aItem) => ProgramListItem.fromJson(aItem as Map<String, dynamic>)).toList();
  }

  Future<TrainingProgram> getProgram(String aId) async
  {
    final res = await _dio.get('/api/training/programs/$aId');
    return TrainingProgram.fromJson(res.data as Map<String, dynamic>);
  }

  Future<TrainingProgram> saveProgram(String? aId, String aName, ScheduleMode aMode, List<ProgramDay> aDays) async
  {
    final data = {'name': aName, 'schedule_mode': aMode.name, 'days': aDays.map((aDay) => aDay.toJson()).toList()};
    final res = aId == null
        ? await _dio.post('/api/training/programs', data: data)
        : await _dio.put('/api/training/programs/$aId', data: data);
    return TrainingProgram.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteProgram(String aId) => _dio.delete('/api/training/programs/$aId');

  Future<void> activateProgram(String aId) => _dio.post('/api/training/programs/$aId/activate');

  Future<void> setTrainingToday(String aDayId) =>
      _dio.put('/api/training/today', data: {'day_id': aDayId, 'date': _dateWire(DateTime.now())});

  Future<TrainingPlan> getTrainingPlan({int aDays = 14}) async
  {
    final res = await _dio.get(
      '/api/training/plan',
      queryParameters: {'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes, 'days': aDays, 'tz': deviceTimeZone()},
    );
    return TrainingPlan.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<Occurrence>> getAgenda(DateTime aFrom, DateTime aTo) async
  {
    final res = await _dio.get('/api/plan', queryParameters: {
      'from': dateWire(aFrom),
      'to': dateWire(aTo),
      'tz': deviceTimeZone(),
    });
    return _list((res.data as Map<String, dynamic>)['occurrences'], Occurrence.fromJson);
  }

  Future<List<PlanEvent>> getPlanEvents() async
  {
    final res = await _dio.get('/api/plan/events');
    return _list(res.data, PlanEvent.fromJson);
  }

  Future<PlanEvent> getPlanEvent(String aId) async
  {
    final res = await _dio.get('/api/plan/events/$aId');
    return PlanEvent.fromJson(res.data as Map<String, dynamic>);
  }

  Future<PlanEvent> savePlanEvent(String? aId, Map<String, dynamic> aPayload) async
  {
    final res = aId == null
        ? await _dio.post('/api/plan/events', data: aPayload)
        : await _dio.put('/api/plan/events/$aId', data: aPayload);
    return PlanEvent.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deletePlanEvent(String aId) => _dio.delete('/api/plan/events/$aId');

  Future<void> saveOccurrence(String aEventId, DateTime aOccDate, PlanState aState, {DateTime? aMovedStart}) =>
      _dio.put('/api/plan/events/$aEventId/occurrences/${dateWire(aOccDate)}', data: {
        'state': aState.name,
        if (aMovedStart != null) 'moved_start': aMovedStart.toUtc().toIso8601String(),
      });

  Future<WorkoutSession> startOccurrence(String aEventId, DateTime aOccDate) async
  {
    final res = await _dio.post('/api/plan/events/$aEventId/occurrences/${dateWire(aOccDate)}/start');
    return WorkoutSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<String>> getTimeZones() async
  {
    final res = await _dio.get('/api/plan/time-zones');
    return (res.data as List<dynamic>).cast<String>();
  }

  Future<PersonTraining> getPersonTraining(String aPersonId) async
  {
    final res = await _dio.get(
      '/api/people/$aPersonId/training',
      queryParameters: {'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes, 'days': 7},
    );
    return PersonTraining.fromJson(res.data as Map<String, dynamic>);
  }

  Future<WorkoutSession> getPersonSession(String aPersonId, String aSessionId) async
  {
    final res = await _dio.get('/api/people/$aPersonId/training/sessions/$aSessionId');
    return WorkoutSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AccountDto> shareWallet(String aWalletId, String aFamilyId, bool aIsShared) async
  {
    final res = await _dio.put('/api/wallets/$aWalletId/shares/$aFamilyId', data: {'is_shared': aIsShared});
    return AccountDto.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<BalanceDoc>> getBalanceDocs(String aWalletId) async
  {
    final res = await _dio.get('/api/wallets/$aWalletId/balance-docs');
    return (res.data as List<dynamic>).map((aItem) => BalanceDoc.fromJson(aItem as Map<String, dynamic>)).toList();
  }

  Map<String, dynamic> _balanceDocBody(DateTime aTs, double aAmount, String? aNote) => {
        'balance_ts': aTs.toUtc().toIso8601String(),
        'amount': moneyWire(aAmount),
        'note': aNote,
      };

  Future<BalanceDoc> createBalanceDoc(String aWalletId, DateTime aTs, double aAmount, String? aNote) async
  {
    final res = await _dio.post('/api/wallets/$aWalletId/balance-docs', data: _balanceDocBody(aTs, aAmount, aNote));
    return BalanceDoc.fromJson(res.data as Map<String, dynamic>);
  }

  Future<BalanceDoc> updateBalanceDoc(String aDocId, DateTime aTs, double aAmount, String? aNote) async
  {
    final res = await _dio.put('/api/balance-docs/$aDocId', data: _balanceDocBody(aTs, aAmount, aNote));
    return BalanceDoc.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteBalanceDoc(String aDocId) async
  {
    await _dio.delete('/api/balance-docs/$aDocId');
  }

  Future<BalanceDoc> writeOffBalance(String aDocId, double aAmount, DateTime aTs, TxCategory? aCategory, String? aNote) async
  {
    final res = await _dio.post('/api/balance-docs/$aDocId/write-offs', data: {
      'amount': moneyWire(aAmount),
      'tx_ts': aTs.toUtc().toIso8601String(),
      'category': aCategory?.name,
      'note': aNote,
    });
    return BalanceDoc.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<SessionSummary>> getSessions({int aLimit = 20}) async
  {
    final res = await _dio.get('/api/training/sessions', queryParameters: {'limit': aLimit});
    return (res.data as List<dynamic>).map((aItem) => SessionSummary.fromJson(aItem as Map<String, dynamic>)).toList();
  }

  Future<WorkoutSession> startSession(String? aDayId) async
  {
    final res = await _dio.post('/api/training/sessions', data: {'day_id': aDayId});
    return WorkoutSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ExerciseProgress> getExerciseProgress(String aExId) async
  {
    final res = await _dio.get('/api/training/exercises/$aExId/progress');
    return ExerciseProgress.fromJson(res.data as Map<String, dynamic>);
  }

  Future<ExerciseProgress> getPersonExerciseProgress(String aPersonId, String aExId) async
  {
    final res = await _dio.get('/api/people/$aPersonId/training/exercises/$aExId/progress');
    return ExerciseProgress.fromJson(res.data as Map<String, dynamic>);
  }

  Future<WorkoutSession> getSession(String aId) async
  {
    final res = await _dio.get('/api/training/sessions/$aId');
    return WorkoutSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<WorkoutSession> saveSession(String aId, String? aNote, List<SessionExercise> aExercises) async
  {
    final res = await _dio.put(
      '/api/training/sessions/$aId',
      data: {'note': aNote, 'exercises': aExercises.map((aExercise) => aExercise.toJson()).toList()},
    );
    return WorkoutSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<WorkoutSession> finishSession(String aId, int aIntensity) async
  {
    final res = await _dio.post('/api/training/sessions/$aId/finish', data: {'intensity': aIntensity});
    return WorkoutSession.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteSession(String aId) => _dio.delete('/api/training/sessions/$aId');

  Future<AiFeatures> getFeatures() async
  {
    final res = await _dio.get('/api/features');
    return AiFeatures.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AiSettings> getAiSettings() async
  {
    final res = await _dio.get('/api/settings/ai');
    return AiSettings.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AiSettings> saveAiSettings(AiSource aSource, int? aDailyLimit, int? aMonthlyLimit) async
  {
    final res = await _dio.put(
      '/api/settings/ai',
      data: {'source': aSource.toJson(), 'daily_limit': aDailyLimit, 'monthly_limit': aMonthlyLimit},
    );
    return AiSettings.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AiKeySaved> saveAiKey(AiProvider aProvider, String aApiKey) async
  {
    final res = await _dio.put('/api/settings/ai/keys/${aProvider.toJson()}', data: {'api_key': aApiKey});
    return AiKeySaved.fromJson(res.data as Map<String, dynamic>);
  }

  Future<AiKey> setAiModel(AiProvider aProvider, String aModel) async
  {
    final res = await _dio.patch('/api/settings/ai/keys/${aProvider.toJson()}', data: {'model': aModel});
    return AiKey.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<AiModel>> getAiModels(AiProvider aProvider) async
  {
    final res = await _dio.get('/api/settings/ai/keys/${aProvider.toJson()}/models');
    return AiModel.listFromJson(res.data);
  }

  Future<void> deleteAiKey(AiProvider aProvider) => _dio.delete('/api/settings/ai/keys/${aProvider.toJson()}');

  Future<RecognizedReceipt> recognizeReceipt(
    String aImageBase64,
    String aMediaType, {
    List<Map<String, dynamic>> aEntered = const [],
  }) async
  {
    final res = await _dio.post(
      '/api/receipts/recognize',
      data: {
        'image': aImageBase64,
        'media_type': aMediaType,
        'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
        if (aEntered.isNotEmpty) 'entered': aEntered,
      },
      options: Options(receiveTimeout: const Duration(seconds: 150), sendTimeout: const Duration(seconds: 60)),
    );
    return RecognizedReceipt.fromJson(res.data as Map<String, dynamic>);
  }

  String _dateWire(DateTime aDate)
  {
    String twoDigits(int aValue) => aValue.toString().padLeft(2, '0');
    return '${aDate.year.toString().padLeft(4, '0')}-${twoDigits(aDate.month)}-${twoDigits(aDate.day)}';
  }
}
