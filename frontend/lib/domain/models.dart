class UserProf {
  final String fName;
  final String lName;

  UserProf({required this.fName, required this.lName});

  factory UserProf.fromJson(Map<String, dynamic> json) => UserProf(
        fName: json['first_name'] ?? '',
        lName: json['last_name'] ?? '',
      );
}

class FamDto {
  final String id;
  final String name;

  FamDto({required this.id, required this.name});

  factory FamDto.fromJson(Map<String, dynamic> json) => FamDto(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
      );
}