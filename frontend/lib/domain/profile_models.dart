import 'dart:math' as math;

import 'finance_models.dart';

enum Sex
{
  male,
  female;

  static Sex? parse(Object? aValue)
  {
    for (final sex in Sex.values)
    {
      if (sex.name == aValue)
      {
        return sex;
      }
    }
    return null;
  }
}

enum ActivityLevel
{
  sedentary('sedentary'),
  light('light'),
  moderate('moderate'),
  active('active'),
  veryActive('very_active');

  final String wire;

  const ActivityLevel(this.wire);

  static ActivityLevel? parse(Object? aValue)
  {
    for (final level in ActivityLevel.values)
    {
      if (level.wire == aValue)
      {
        return level;
      }
    }
    return null;
  }
}

enum MetricGroup
{
  body,
  composition,
  measures;

  static MetricGroup? parse(Object? aValue)
  {
    for (final group in MetricGroup.values)
    {
      if (group.name == aValue)
      {
        return group;
      }
    }
    return null;
  }
}

enum MetricUnit
{
  cm,
  kg,
  percent,
  level,
}

enum BodyMetric
{
  height('height', MetricGroup.body, MetricUnit.cm, 30, 250),
  weight('weight', MetricGroup.body, MetricUnit.kg, 1, 350),
  bodyFat('body_fat', MetricGroup.composition, MetricUnit.percent, 2, 75),
  muscleMass('muscle_mass', MetricGroup.composition, MetricUnit.kg, 1, 150),
  skeletalMuscle('skeletal_muscle', MetricGroup.composition, MetricUnit.kg, 1, 100),
  boneMass('bone_mass', MetricGroup.composition, MetricUnit.kg, 0.2, 10),
  bodyWater('body_water', MetricGroup.composition, MetricUnit.percent, 20, 85),
  protein('protein', MetricGroup.composition, MetricUnit.percent, 5, 30),
  visceralFat('visceral_fat', MetricGroup.composition, MetricUnit.level, 1, 60),
  neck('neck', MetricGroup.measures, MetricUnit.cm, 5, 250),
  chest('chest', MetricGroup.measures, MetricUnit.cm, 5, 250),
  waist('waist', MetricGroup.measures, MetricUnit.cm, 5, 250),
  hips('hips', MetricGroup.measures, MetricUnit.cm, 5, 250),
  bicepsLeft('biceps_left', MetricGroup.measures, MetricUnit.cm, 5, 250),
  bicepsRight('biceps_right', MetricGroup.measures, MetricUnit.cm, 5, 250),
  forearmLeft('forearm_left', MetricGroup.measures, MetricUnit.cm, 5, 250),
  forearmRight('forearm_right', MetricGroup.measures, MetricUnit.cm, 5, 250),
  thighLeft('thigh_left', MetricGroup.measures, MetricUnit.cm, 5, 250),
  thighRight('thigh_right', MetricGroup.measures, MetricUnit.cm, 5, 250),
  calfLeft('calf_left', MetricGroup.measures, MetricUnit.cm, 5, 250),
  calfRight('calf_right', MetricGroup.measures, MetricUnit.cm, 5, 250);

  final String wire;
  final MetricGroup group;
  final MetricUnit unit;
  final double min;
  final double max;

  const BodyMetric(this.wire, this.group, this.unit, this.min, this.max);

  bool isValid(double aValue) => aValue >= min && aValue <= max;

  static BodyMetric? parse(Object? aValue)
  {
    for (final metric in BodyMetric.values)
    {
      if (metric.wire == aValue)
      {
        return metric;
      }
    }
    return null;
  }

  static List<BodyMetric> ofGroup(MetricGroup aGroup) => BodyMetric.values.where((aMetric) => aMetric.group == aGroup).toList();
}

class MetricValue
{
  final BodyMetric metric;
  final double value;
  final DateTime measuredTs;
  final double? prevValue;
  final DateTime? prevTs;

  const MetricValue({required this.metric, required this.value, required this.measuredTs, this.prevValue, this.prevTs});

  double? get delta => prevValue == null ? null : value - prevValue!;

  static MetricValue? fromJson(Map<String, dynamic> aJson)
  {
    final metric = BodyMetric.parse(aJson['metric']);
    if (metric == null)
    {
      return null;
    }
    return MetricValue(
      metric: metric,
      value: parseDecimal(aJson['value']),
      measuredTs: parseTs(aJson['measured_ts']),
      prevValue: parseDecimalOrNull(aJson['prev_value']),
      prevTs: parseTsOrNull(aJson['prev_ts']),
    );
  }
}

class ProfileSharing
{
  final String familyId;
  final String familyName;
  final bool isBodyShared;
  final bool isCompositionShared;
  final bool isMeasuresShared;

  const ProfileSharing({
    required this.familyId,
    required this.familyName,
    required this.isBodyShared,
    required this.isCompositionShared,
    required this.isMeasuresShared,
  });

  factory ProfileSharing.fromJson(Map<String, dynamic> aJson) => ProfileSharing(
        familyId: aJson['family_id'] as String,
        familyName: aJson['family_name'] as String,
        isBodyShared: aJson['is_body_shared'] as bool,
        isCompositionShared: aJson['is_composition_shared'] as bool,
        isMeasuresShared: aJson['is_measures_shared'] as bool,
      );

  bool isShared(MetricGroup aGroup) => switch (aGroup)
  {
    MetricGroup.body => isBodyShared,
    MetricGroup.composition => isCompositionShared,
    MetricGroup.measures => isMeasuresShared,
  };

  ProfileSharing withGroup(MetricGroup aGroup, bool aIsShared) => ProfileSharing(
        familyId: familyId,
        familyName: familyName,
        isBodyShared: aGroup == MetricGroup.body ? aIsShared : isBodyShared,
        isCompositionShared: aGroup == MetricGroup.composition ? aIsShared : isCompositionShared,
        isMeasuresShared: aGroup == MetricGroup.measures ? aIsShared : isMeasuresShared,
      );

  Map<String, dynamic> toJson() => {
        'is_body_shared': isBodyShared,
        'is_composition_shared': isCompositionShared,
        'is_measures_shared': isMeasuresShared,
      };
}

class PersonProfile
{
  final String id;
  final String firstName;
  final String lastName;
  final String? email;
  final DateTime? birthDate;
  final int? age;
  final Sex? sex;
  final ActivityLevel? activity;
  final bool isSelf;
  final bool isManaged;
  final bool canEdit;
  final List<MetricGroup> visibleGroups;
  final List<MetricValue> latest;
  final List<ProfileSharing> sharing;

  const PersonProfile({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.email,
    required this.birthDate,
    required this.age,
    required this.sex,
    required this.activity,
    required this.isSelf,
    required this.isManaged,
    required this.canEdit,
    required this.visibleGroups,
    required this.latest,
    required this.sharing,
  });

  String get fullName => '$firstName $lastName'.trim();

  factory PersonProfile.fromJson(Map<String, dynamic> aJson) => PersonProfile(
        id: aJson['id'] as String,
        firstName: aJson['first_name'] as String,
        lastName: aJson['last_name'] as String,
        email: aJson['email'] as String?,
        birthDate: aJson['birth_date'] == null ? null : DateTime.parse(aJson['birth_date'] as String),
        age: aJson['age'] as int?,
        sex: Sex.parse(aJson['sex']),
        activity: ActivityLevel.parse(aJson['activity']),
        isSelf: aJson['is_self'] as bool,
        isManaged: aJson['is_managed'] as bool,
        canEdit: aJson['can_edit'] as bool,
        visibleGroups: (aJson['visible_groups'] as List<dynamic>).map(MetricGroup.parse).whereType<MetricGroup>().toList(),
        latest: (aJson['latest'] as List<dynamic>)
            .map((aItem) => MetricValue.fromJson(aItem as Map<String, dynamic>))
            .whereType<MetricValue>()
            .toList(),
        sharing: (aJson['sharing'] as List<dynamic>)
            .map((aItem) => ProfileSharing.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  MetricValue? latestOf(BodyMetric aMetric)
  {
    for (final value in latest)
    {
      if (value.metric == aMetric)
      {
        return value;
      }
    }
    return null;
  }
}

class BodyValue
{
  final BodyMetric metric;
  final double value;

  const BodyValue(this.metric, this.value);

  Map<String, dynamic> toJson() => {'metric': metric.wire, 'value': value.toStringAsFixed(2)};
}

class BodyEntry
{
  final String id;
  final DateTime measuredTs;
  final String? note;
  final List<BodyValue> values;

  const BodyEntry({required this.id, required this.measuredTs, required this.note, required this.values});

  factory BodyEntry.fromJson(Map<String, dynamic> aJson) => BodyEntry(
        id: aJson['id'] as String,
        measuredTs: parseTs(aJson['measured_ts']),
        note: aJson['note'] as String?,
        values: (aJson['values'] as List<dynamic>)
            .map((aItem) => aItem as Map<String, dynamic>)
            .where((aItem) => BodyMetric.parse(aItem['metric']) != null)
            .map((aItem) => BodyValue(BodyMetric.parse(aItem['metric'])!, parseDecimal(aItem['value'])))
            .toList(),
      );

  double? valueOf(BodyMetric aMetric)
  {
    for (final value in values)
    {
      if (value.metric == aMetric)
      {
        return value.value;
      }
    }
    return null;
  }
}

class MetricPoint
{
  final String entryId;
  final DateTime measuredTs;
  final double value;

  const MetricPoint({required this.entryId, required this.measuredTs, required this.value});

  factory MetricPoint.fromJson(Map<String, dynamic> aJson) => MetricPoint(
        entryId: aJson['entry_id'] as String,
        measuredTs: parseTs(aJson['measured_ts']),
        value: parseDecimal(aJson['value']),
      );
}

List<double> trendOf(List<MetricPoint> aPoints, {double aDailySmoothing = 0.1})
{
  final trend = <double>[];
  for (var index = 0; index < aPoints.length; index++)
  {
    if (index == 0)
    {
      trend.add(aPoints.first.value);
      continue;
    }
    final days = aPoints[index].measuredTs.difference(aPoints[index - 1].measuredTs).inMinutes / Duration.minutesPerDay;
    final weight = 1 - math.pow(1 - aDailySmoothing, days.clamp(0.0, 365.0)).toDouble();
    trend.add(trend.last + weight * (aPoints[index].value - trend.last));
  }
  return trend;
}
