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