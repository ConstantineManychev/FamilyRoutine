enum MemberRole
{
  admin,
  standard;

  static MemberRole fromJson(Object? aValue) => aValue == 'admin' ? MemberRole.admin : MemberRole.standard;

  String toJson() => name;
}

class UserProf
{
  final String id;
  final String email;
  final String fName;
  final String lName;

  const UserProf({required this.id, required this.email, required this.fName, required this.lName});

  factory UserProf.fromJson(Map<String, dynamic> aJson) => UserProf(
        id: aJson['id'] as String,
        email: aJson['email'] as String? ?? '',
        fName: aJson['first_name'] as String? ?? '',
        lName: aJson['last_name'] as String? ?? '',
      );
}

class RegisterData
{
  final String fName;
  final String lName;
  final String email;
  final String password;
  final String birthDate;

  const RegisterData({
    required this.fName,
    required this.lName,
    required this.email,
    required this.password,
    required this.birthDate,
  });

  Map<String, dynamic> toJson() => {
        'first_name': fName,
        'last_name': lName,
        'email': email,
        'password': password,
        'birth_date': birthDate,
      };
}

class DictMetaDto
{
  final String id;
  final String name;

  const DictMetaDto({required this.id, required this.name});

  factory DictMetaDto.fromJson(Map<String, dynamic> aJson) => DictMetaDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
      );
}

class FamDto
{
  final String id;
  final String name;
  final MemberRole role;
  final int memberCount;

  const FamDto({required this.id, required this.name, required this.role, required this.memberCount});

  bool get isAdmin => role == MemberRole.admin;

  factory FamDto.fromJson(Map<String, dynamic> aJson) => FamDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        role: MemberRole.fromJson(aJson['role']),
        memberCount: (aJson['member_count'] as num?)?.toInt() ?? 1,
      );
}

class FamMemberDto
{
  final String id;
  final String fName;
  final String lName;
  final MemberRole role;

  const FamMemberDto({required this.id, required this.fName, required this.lName, required this.role});

  factory FamMemberDto.fromJson(Map<String, dynamic> aJson) => FamMemberDto(
        id: aJson['id'] as String,
        fName: aJson['first_name'] as String? ?? '',
        lName: aJson['last_name'] as String? ?? '',
        role: MemberRole.fromJson(aJson['role']),
      );
}

class FamDetailDto
{
  final String id;
  final String name;
  final MemberRole myRole;
  final List<FamMemberDto> members;

  const FamDetailDto({required this.id, required this.name, required this.myRole, required this.members});

  bool get isAdmin => myRole == MemberRole.admin;

  factory FamDetailDto.fromJson(Map<String, dynamic> aJson) => FamDetailDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        myRole: MemberRole.fromJson(aJson['my_role']),
        members: (aJson['members'] as List? ?? const [])
            .map((aItem) => FamMemberDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class FamInviteDto
{
  final String id;
  final MemberRole role;
  final String? label;
  final DateTime expiresTs;

  const FamInviteDto({required this.id, required this.role, this.label, required this.expiresTs});

  factory FamInviteDto.fromJson(Map<String, dynamic> aJson) => FamInviteDto(
        id: aJson['id'] as String,
        role: MemberRole.fromJson(aJson['role']),
        label: aJson['label'] as String?,
        expiresTs: DateTime.parse(aJson['expires_ts'] as String).toLocal(),
      );
}

class CreatedInviteDto extends FamInviteDto
{
  final String code;

  const CreatedInviteDto({
    required super.id,
    required this.code,
    required super.role,
    super.label,
    required super.expiresTs,
  });

  factory CreatedInviteDto.fromJson(Map<String, dynamic> aJson) => CreatedInviteDto(
        id: aJson['id'] as String,
        code: aJson['code'] as String,
        role: MemberRole.fromJson(aJson['role']),
        label: aJson['label'] as String?,
        expiresTs: DateTime.parse(aJson['expires_ts'] as String).toLocal(),
      );
}

class AccountDto
{
  final String id;
  final String? userId;
  final String? familyId;
  final String currId;
  final String accountType;
  final String? bankType;
  final String name;
  final String? mask;
  final bool isSyncTokenSet;
  final bool isActive;
  final bool isEditable;

  const AccountDto({
    required this.id,
    this.userId,
    this.familyId,
    required this.currId,
    required this.accountType,
    this.bankType,
    required this.name,
    this.mask,
    required this.isSyncTokenSet,
    required this.isActive,
    required this.isEditable,
  });

  bool get isPersonal => familyId == null;

  factory AccountDto.fromJson(Map<String, dynamic> aJson) => AccountDto(
        id: aJson['id'] as String,
        userId: aJson['user_id'] as String?,
        familyId: aJson['family_id'] as String?,
        currId: aJson['curr_id'] as String,
        accountType: aJson['account_type'] as String? ?? 'cash',
        bankType: aJson['bank_type'] as String?,
        name: aJson['name'] as String? ?? '',
        mask: aJson['mask'] as String?,
        isSyncTokenSet: aJson['is_sync_token_set'] as bool? ?? false,
        isActive: aJson['is_active'] as bool? ?? true,
        isEditable: aJson['is_editable'] as bool? ?? false,
      );
}

class CurrencyDto
{
  final String id;
  final String code;

  const CurrencyDto({required this.id, required this.code});

  factory CurrencyDto.fromJson(Map<String, dynamic> aJson) => CurrencyDto(
        id: aJson['id'] as String,
        code: aJson['code'] as String,
      );
}

class CountryDto
{
  final String id;
  final String code;
  final String name;

  const CountryDto({required this.id, required this.code, required this.name});

  factory CountryDto.fromJson(Map<String, dynamic> aJson) => CountryDto(
        id: aJson['id'] as String,
        code: aJson['code'] as String,
        name: aJson['name'] as String,
      );
}

class CityDto
{
  final String id;
  final String countryId;
  final String name;
  final bool isEditable;

  const CityDto({required this.id, required this.countryId, required this.name, required this.isEditable});

  factory CityDto.fromJson(Map<String, dynamic> aJson) => CityDto(
        id: aJson['id'] as String,
        countryId: aJson['country_id'] as String,
        name: aJson['name'] as String,
        isEditable: aJson['is_editable'] as bool? ?? false,
      );
}

class StreetDto
{
  final String id;
  final String cityId;
  final String name;
  final bool isEditable;

  const StreetDto({required this.id, required this.cityId, required this.name, required this.isEditable});

  factory StreetDto.fromJson(Map<String, dynamic> aJson) => StreetDto(
        id: aJson['id'] as String,
        cityId: aJson['city_id'] as String,
        name: aJson['name'] as String,
        isEditable: aJson['is_editable'] as bool? ?? false,
      );
}

class PlaceAddrDto
{
  final String? id;
  final bool isMain;
  final String countryId;
  final String cityId;
  final String streetId;
  final String houseNum;
  final String? apt;
  final String zip;
  final String? merchantId;

  const PlaceAddrDto({
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

  factory PlaceAddrDto.fromJson(Map<String, dynamic> aJson) => PlaceAddrDto(
        id: aJson['id'] as String?,
        isMain: aJson['is_main'] as bool? ?? false,
        countryId: aJson['country_id'] as String,
        cityId: aJson['city_id'] as String,
        streetId: aJson['street_id'] as String,
        houseNum: aJson['house_num'] as String? ?? '',
        apt: aJson['apt'] as String?,
        zip: aJson['zip'] as String? ?? '',
        merchantId: aJson['merchant_id'] as String?,
      );

  PlaceAddrDto copyWith({bool? aIsMain}) => PlaceAddrDto(
        id: id,
        isMain: aIsMain ?? isMain,
        countryId: countryId,
        cityId: cityId,
        streetId: streetId,
        houseNum: houseNum,
        apt: apt,
        zip: zip,
        merchantId: merchantId,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
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

class PlaceDto
{
  final String id;
  final String name;
  final List<PlaceAddrDto> addrs;

  const PlaceDto({required this.id, required this.name, required this.addrs});

  PlaceAddrDto? get mainAddr
  {
    for (final addr in addrs)
    {
      if (addr.isMain)
      {
        return addr;
      }
    }
    return addrs.isEmpty ? null : addrs.first;
  }

  factory PlaceDto.fromJson(Map<String, dynamic> aJson) => PlaceDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        addrs: (aJson['addrs'] as List? ?? const [])
            .map((aItem) => PlaceAddrDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

enum MuscGrpType { chest, back, legs, shoulders, arms, core, cardio, fullBody }

extension MuscGrpTypeJson on MuscGrpType
{
  static const Map<MuscGrpType, String> _wireNames = {
    MuscGrpType.chest: 'chest',
    MuscGrpType.back: 'back',
    MuscGrpType.legs: 'legs',
    MuscGrpType.shoulders: 'shoulders',
    MuscGrpType.arms: 'arms',
    MuscGrpType.core: 'core',
    MuscGrpType.cardio: 'cardio',
    MuscGrpType.fullBody: 'full_body',
  };

  String get wireName => _wireNames[this]!;

  static MuscGrpType parse(Object? aValue)
  {
    for (final entry in _wireNames.entries)
    {
      if (entry.value == aValue)
      {
        return entry.key;
      }
    }
    return MuscGrpType.fullBody;
  }
}

class ExMuscGrpDto
{
  final MuscGrpType grp;
  final double pct;

  const ExMuscGrpDto({required this.grp, required this.pct});

  factory ExMuscGrpDto.fromJson(Map<String, dynamic> aJson) => ExMuscGrpDto(
        grp: MuscGrpTypeJson.parse(aJson['grp']),
        pct: (aJson['pct'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {'grp': grp.wireName, 'pct': pct};
}

class DictExDto
{
  final String id;
  final String name;
  final String exType;
  final double metVal;
  final String weightType;
  final double bwPct;
  final bool isCustom;
  final List<ExMuscGrpDto> muscGrps;

  const DictExDto({
    required this.id,
    required this.name,
    required this.exType,
    required this.metVal,
    required this.weightType,
    required this.bwPct,
    required this.isCustom,
    required this.muscGrps,
  });

  factory DictExDto.fromJson(Map<String, dynamic> aJson) => DictExDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        exType: aJson['ex_type'] as String? ?? 'strength',
        metVal: (aJson['met_val'] as num).toDouble(),
        weightType: aJson['weight_type'] as String? ?? 'external',
        bwPct: (aJson['bw_pct'] as num?)?.toDouble() ?? 0.0,
        isCustom: aJson['is_custom'] as bool? ?? false,
        muscGrps: (aJson['musc_grps'] as List? ?? const [])
            .map((aItem) => ExMuscGrpDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}
