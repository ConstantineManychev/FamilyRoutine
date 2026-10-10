import 'finance_models.dart';

enum RoutineStatus
{
  work,
  meal,
  home,
  transit,
  leisure,
  gym,
  sleep,
  school,
  other;

  static RoutineStatus fromJson(Object? aValue) =>
      values.firstWhere((aStatus) => aStatus.name == aValue, orElse: () => RoutineStatus.other);

  String toJson() => name;
}

class StatusMarkDto
{
  final String id;
  final RoutineStatus status;
  final String? note;
  final DateTime startTs;
  final DateTime? endTs;

  const StatusMarkDto({
    required this.id,
    required this.status,
    this.note,
    required this.startTs,
    this.endTs,
  });

  bool isActiveAt(DateTime aMoment) => !startTs.isAfter(aMoment) && (endTs == null || endTs!.isAfter(aMoment));

  factory StatusMarkDto.fromJson(Map<String, dynamic> aJson) => StatusMarkDto(
        id: aJson['id'] as String,
        status: RoutineStatus.fromJson(aJson['status']),
        note: aJson['note'] as String?,
        startTs: parseTs(aJson['start_ts']),
        endTs: aJson['end_ts'] == null ? null : parseTs(aJson['end_ts']),
      );
}

class TimelineMemberDto
{
  final String userId;
  final String fName;
  final String lName;
  final bool isMe;
  final List<StatusMarkDto> marks;

  const TimelineMemberDto({
    required this.userId,
    required this.fName,
    required this.lName,
    required this.isMe,
    required this.marks,
  });

  String get fullName => '$fName $lName'.trim();

  StatusMarkDto? markAt(DateTime aMoment)
  {
    for (final mark in marks)
    {
      if (mark.isActiveAt(aMoment))
      {
        return mark;
      }
    }
    return null;
  }

  factory TimelineMemberDto.fromJson(Map<String, dynamic> aJson) => TimelineMemberDto(
        userId: aJson['user_id'] as String,
        fName: aJson['first_name'] as String? ?? '',
        lName: aJson['last_name'] as String? ?? '',
        isMe: aJson['is_me'] as bool? ?? false,
        marks: (aJson['marks'] as List? ?? const [])
            .map((aItem) => StatusMarkDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class TimelineDto
{
  final String? familyId;
  final String? familyName;
  final List<TimelineMemberDto> members;

  const TimelineDto({this.familyId, this.familyName, required this.members});

  factory TimelineDto.fromJson(Map<String, dynamic> aJson) => TimelineDto(
        familyId: aJson['family_id'] as String?,
        familyName: aJson['family_name'] as String?,
        members: (aJson['members'] as List? ?? const [])
            .map((aItem) => TimelineMemberDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

enum WidgetKind
{
  myStatus('my_status'),
  familyTimeline('family_timeline'),
  cashflow('cashflow'),
  familyList('family_list');

  final String wire;

  const WidgetKind(this.wire);

  static WidgetKind? fromJson(Object? aValue)
  {
    for (final kind in values)
    {
      if (kind.wire == aValue)
      {
        return kind;
      }
    }
    return null;
  }
}

class WidgetDto
{
  final String id;
  final WidgetKind kind;
  final String? familyId;
  final String? familyName;
  final bool isAvailable;

  const WidgetDto({
    required this.id,
    required this.kind,
    this.familyId,
    this.familyName,
    required this.isAvailable,
  });

  factory WidgetDto.fromJson(Map<String, dynamic> aJson) => WidgetDto(
        id: aJson['id'] as String,
        kind: WidgetKind.fromJson(aJson['kind']) ?? WidgetKind.myStatus,
        familyId: aJson['family_id'] as String?,
        familyName: aJson['family_name'] as String?,
        isAvailable: aJson['is_available'] as bool? ?? true,
      );
}

class DashboardDto
{
  final String id;
  final String name;
  final List<WidgetDto> widgets;

  const DashboardDto({required this.id, required this.name, required this.widgets});

  factory DashboardDto.fromJson(Map<String, dynamic> aJson) => DashboardDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        widgets: (aJson['widgets'] as List? ?? const [])
            .where((aItem) => WidgetKind.fromJson((aItem as Map<String, dynamic>)['kind']) != null)
            .map((aItem) => WidgetDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}
