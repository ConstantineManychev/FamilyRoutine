class UserProf {
  final String id;
  final String fName;
  final String lName;

  UserProf({
    required this.id,
    required this.fName,
    required this.lName,
  });

  factory UserProf.fromJson(Map<String, dynamic> json) => UserProf(
        id: json['id'] ?? '',
        fName: json['first_name'] ?? '',
        lName: json['last_name'] ?? '',
      );
}

class FamDto {
  final String id;
  final String name;
  final String role;
  final int memberCount;

  FamDto({required this.id, required this.name, required this.role, required this.memberCount});

  factory FamDto.fromJson(Map<String, dynamic> json) => FamDto(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
        role: json['role'] ?? 'standard',
        memberCount: json['member_count'] ?? 1,
      );
}

class DictMetaDto {
  final String id;
  final String name;

  DictMetaDto({required this.id, required this.name});

  factory DictMetaDto.fromJson(Map<String, dynamic> json) => DictMetaDto(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
      );
}

class FamMemberDto {
  final String id;
  final String fName;
  final String lName;
  final String role;

  FamMemberDto({required this.id, required this.fName, required this.lName, required this.role});

  factory FamMemberDto.fromJson(Map<String, dynamic> json) => FamMemberDto(
        id: json['id'] ?? '',
        fName: json['first_name'] ?? '',
        lName: json['last_name'] ?? '',
        role: json['role'] ?? 'standard',
      );
}

class FamDetailDto {
  final String id;
  final String name;
  final List<FamMemberDto> members;

  FamDetailDto({required this.id, required this.name, required this.members});

  factory FamDetailDto.fromJson(Map<String, dynamic> json) => FamDetailDto(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
        members: (json['members'] as List?)?.map((e) => FamMemberDto.fromJson(e)).toList() ?? [],
      );
}

class AccountDto {
  final String id;
  final String? userId;
  final String? familyId;
  final String currId;
  final String accountType;
  final String? bankType;
  final String name;
  final String? mask;
  final Map<String, dynamic>? syncCredentials;
  final bool isActive;

  AccountDto({
    required this.id,
    this.userId,
    this.familyId,
    required this.currId,
    required this.accountType,
    this.bankType,
    required this.name,
    this.mask,
    this.syncCredentials,
    required this.isActive,
  });

  factory AccountDto.fromJson(Map<String, dynamic> json) => AccountDto(
        id: json['id'] ?? '',
        userId: json['user_id'],
        familyId: json['family_id'],
        currId: json['curr_id'] ?? '',
        accountType: json['account_type'] ?? 'cash',
        bankType: json['bank_type'],
        name: json['name'] ?? '',
        mask: json['mask'],
        syncCredentials: json['sync_credentials'],
        isActive: json['is_active'] ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'user_id': userId,
        'family_id': familyId,
        'curr_id': currId,
        'account_type': accountType,
        'bank_type': bankType,
        'name': name,
        'mask': mask,
        'sync_credentials': syncCredentials,
        'is_active': isActive,
      };
}

class CurrencyDto {
  final String id;
  final String code;

  CurrencyDto({required this.id, required this.code});

  factory CurrencyDto.fromJson(Map<String, dynamic> json) => CurrencyDto(
        id: json['id'] ?? '',
        code: json['code'] ?? '',
      );
}

class CountryDto {
  final String id;
  final String code;
  final String name;

  CountryDto({required this.id, required this.code, required this.name});

  factory CountryDto.fromJson(Map<String, dynamic> json) => CountryDto(
        id: json['id'],
        code: json['code'],
        name: json['name'],
      );
}

class CityDto {
  final String id;
  final String countryId;
  final String name;

  CityDto({required this.id, required this.countryId, required this.name});

  factory CityDto.fromJson(Map<String, dynamic> json) => CityDto(
        id: json['id'],
        countryId: json['country_id'],
        name: json['name'],
      );
}

class StreetDto {
  final String id;
  final String cityId;
  final String name;

  StreetDto({required this.id, required this.cityId, required this.name});

  factory StreetDto.fromJson(Map<String, dynamic> json) => StreetDto(
        id: json['id'],
        cityId: json['city_id'],
        name: json['name'],
      );
}

class PlaceAddrDto {
  final String? id;
  final bool isMain;
  final String countryId;
  final String cityId;
  final String streetId;
  final String houseNum;
  final String? apt;
  final String zip;
  final String? merchantId;

  PlaceAddrDto({
    this.id,
    required this.isMain,
    required this.countryId,
    required this.cityId,
    required this.streetId,
    required this.houseNum,
    this.apt,
    required this.zip,
    this.merchantId,
  });

  factory PlaceAddrDto.fromJson(Map<String, dynamic> json) => PlaceAddrDto(
        id: json['id'],
        isMain: json['is_main'] ?? false,
        countryId: json['country_id'],
        cityId: json['city_id'],
        streetId: json['street_id'],
        houseNum: json['house_num'],
        apt: json['apt'],
        zip: json['zip'],
        merchantId: json['merchant_id'],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'is_main': isMain,
        'country_id': countryId,
        'city_id': cityId,
        'street_id': streetId,
        'house_num': houseNum,
        'apt': apt,
        'zip': zip,
        'merchant_id': merchantId,
      };
}

class PlaceDto {
  final String id;
  final String name;
  final List<PlaceAddrDto> addrs;

  PlaceDto({required this.id, required this.name, required this.addrs});

  factory PlaceDto.fromJson(Map<String, dynamic> json) => PlaceDto(
        id: json['id'],
        name: json['name'],
        addrs: (json['addrs'] as List?)?.map((e) => PlaceAddrDto.fromJson(e)).toList() ?? [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'addrs': addrs.map((e) => e.toJson()).toList(),
      };
}

class BodySnapDto {
  final String id;
  final String userId;
  final double weight;
  final double height;
  final double? fatPct;
  final double? muscPct;
  final double? skelMuscPct;
  final DateTime recTs;

  BodySnapDto({
    required this.id,
    required this.userId,
    required this.weight,
    required this.height,
    this.fatPct,
    this.muscPct,
    this.skelMuscPct,
    required this.recTs,
  });

  factory BodySnapDto.fromJson(Map<String, dynamic> json) => BodySnapDto(
        id: json['id'],
        userId: json['user_id'],
        weight: json['weight'],
        height: json['height'],
        fatPct: json['fat_pct'],
        muscPct: json['musc_pct'],
        skelMuscPct: json['skel_musc_pct'],
        recTs: DateTime.parse(json['rec_ts']),
      );
}

class EnergyNodeDto {
  final DateTime ts;
  final String eventType;
  final double val;
  final double cumVal;

  EnergyNodeDto({
    required this.ts,
    required this.eventType,
    required this.val,
    required this.cumVal,
  });

  factory EnergyNodeDto.fromJson(Map<String, dynamic> json) => EnergyNodeDto(
        ts: DateTime.parse(json['ts']),
        eventType: json['event_type'],
        val: json['val'],
        cumVal: json['cum_val'],
      );
}

class FamBudgetDto {
  final String currCode;
  final double totalBalance;

  FamBudgetDto({
    required this.currCode,
    required this.totalBalance,
  });

  factory FamBudgetDto.fromJson(Map<String, dynamic> json) => FamBudgetDto(
        currCode: json['curr_code'],
        totalBalance: json['total_balance'],
      );
}

class ExMuscleDto {
  final String muscle;
  final double pct;

  ExMuscleDto({required this.muscle, required this.pct});

  factory ExMuscleDto.fromJson(Map<String, dynamic> json) => ExMuscleDto(
        muscle: json['muscle'],
        pct: (json['pct'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'muscle': muscle,
        'pct': pct,
      };
}

class ExDto {
  final String id;
  final String name;
  final String exType;
  final double metVal;
  final bool isCustom;
  final String weightType;
  final double bwPct;
  final List<ExMuscleDto> muscles;

  ExDto({
    required this.id,
    required this.name,
    required this.exType,
    required this.metVal,
    required this.isCustom,
    required this.weightType,
    required this.bwPct,
    required this.muscles,
  });

  factory ExDto.fromJson(Map<String, dynamic> json) => ExDto(
        id: json['id'],
        name: json['name'],
        exType: json['ex_type'],
        metVal: (json['met_val'] as num).toDouble(),
        isCustom: json['is_custom'] ?? false,
        weightType: json['weight_type'] ?? 'external',
        bwPct: (json['bw_pct'] as num).toDouble(),
        muscles: (json['muscles'] as List?)?.map((e) => ExMuscleDto.fromJson(e)).toList() ?? [],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'ex_type': exType,
        'met_val': metVal,
        'is_custom': isCustom,
        'weight_type': weightType,
        'bw_pct': bwPct,
        'muscles': muscles.map((e) => e.toJson()).toList(),
      };
}