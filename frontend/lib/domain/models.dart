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