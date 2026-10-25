import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> locales = ['en', 'ru', 'de', 'fr', 'ja', 'zh'];

const Map<String, List<String>> dynamicKeys = {
  'errors': [
    'VALIDATION', 'UNAUTHENTICATED', 'INVALID_CREDENTIALS', 'FORBIDDEN', 'NOT_FOUND', 'ALREADY_EXISTS',
    'EMAIL_TAKEN', 'IN_USE', 'OWNER_PROTECTED', 'OWNER_MUST_TRANSFER', 'TOO_MANY_INVITES', 'TOO_MANY_REQUESTS',
    'INTERNAL', 'NETWORK', 'UNKNOWN', 'BANK_NOT_CONFIGURED', 'ALREADY_CONNECTED', 'BANK_UNAVAILABLE', 'BANK_LINKED',
    'BANK_APP_REJECTED', 'BANK_APP_INACTIVE', 'BANK_REJECTED', 'BARCODE_TAKEN', 'RECOGNITION_DISABLED',
    'RECOGNITION_UNAVAILABLE', 'RECEIPT_UNREADABLE', 'NOT_A_RECEIPT', 'AI_KEY_REJECTED', 'AI_MODEL_REJECTED',
    'AI_QUOTA_EXCEEDED', 'AI_SERVER_UNAVAILABLE', 'AI_KEY_MISSING', 'AI_OWN_KEYS_DISABLED', 'AI_NO_MODELS',
    'AI_PROVIDER_UNAVAILABLE', 'WRONG_PASSWORD', 'CHILD_PROFILE', 'SESSION_ACTIVE', 'SESSION_FINISHED', 'TOO_MANY_PROGRAMS',
    'TOO_MANY_DISHES', 'TOO_MANY_ENTRIES', 'CAT_EXISTS', 'CAT_IN_USE', 'CAT_HAS_CHILDREN', 'TOO_MANY_CATS', 'MARK_OVERLAP',
    'TASK_DONE', 'TASK_OPEN', 'TASK_ARCHIVED', 'TOO_MANY_TASKS', 'TASK_LOG_FULL', 'TOPIC_TOO_DEEP', 'TOPIC_CYCLE',
    'TOPIC_HAS_CHILDREN', 'TOO_MANY_TOPICS', 'TOO_MANY_NOTES', 'STOCK_LOT_USED', 'STOCK_FROM_RECEIPT', 'TOO_MANY_LOTS', 'TOO_MANY_MARKS', 'PLAN_DONE',
    'CAT_NO_FOOD',
  ],
  'ai': ['hint_anthropic', 'hint_openai', 'hint_gemini'],
  'metrics': [
    'height', 'weight', 'body_fat', 'muscle_mass', 'skeletal_muscle', 'bone_mass', 'body_water', 'protein', 'visceral_fat',
    'neck', 'chest', 'waist', 'hips', 'biceps_left', 'biceps_right', 'forearm_left', 'forearm_right', 'thigh_left',
    'thigh_right', 'calf_left', 'calf_right', 'group_body', 'group_composition', 'group_measures',
  ],
  'training': [
    'mode_queue', 'mode_intervals', 'mode_weekdays', 'mode_queue_hint', 'mode_intervals_hint', 'mode_weekdays_hint',
    'days_count.one', 'days_count.other', 'rest_days.zero', 'rest_days.other',
  ],
  'profile': [
    'sex_male', 'sex_female', 'activity_sedentary', 'activity_light', 'activity_moderate', 'activity_active',
    'activity_very_active', 'years.one', 'years.few', 'years.many', 'years.other',
  ],
  'bank': [
    'provider_monobank', 'provider_enable_banking', 'status_pending', 'status_active', 'status_error', 'status_expired',
    'error_UNAUTHORIZED', 'error_APP_INACTIVE', 'error_RATE_LIMITED', 'error_REJECTED', 'error_UNAVAILABLE', 'error_INTERNAL',
  ],
  'finance': [
    'period_day', 'period_week', 'period_month', 'period_quarter', 'grouping_day', 'grouping_week', 'grouping_month',
    'chart_kind_bars', 'chart_kind_balance', 'chart_kind_bars_hint', 'chart_kind_balance_hint',
  ],
  'finance.cat': [
    'groceries', 'restaurants', 'transport', 'fuel', 'shopping', 'health', 'utilities', 'entertainment', 'travel',
    'education', 'home', 'cash', 'transfer', 'fees', 'income', 'other', 'none',
  ],
  'family.roles': ['owner', 'admin', 'standard'],
  'wallet': ['type_cash', 'type_card', 'type_bank_acc', 'bank_monobank', 'bank_aib', 'bank_other'],
  'exercises.types': ['cardio', 'strength', 'flexibility', 'mixed'],
  'exercises.w_types': ['external', 'hybrid', 'bodyweight'],
  'exercises.muscle_grps': ['chest', 'back', 'legs', 'shoulders', 'arms', 'core', 'cardio', 'full_body'],
  'dicts': ['events', 'exercises', 'items'],
  'items': [
    'kind_product', 'kind_service', 'kind_food',
    'unit_piece', 'unit_kilogram', 'unit_liter', 'unit_meter', 'unit_square_meter', 'unit_hour',
    'unit_short_piece', 'unit_short_kilogram', 'unit_short_liter', 'unit_short_meter', 'unit_short_square_meter',
    'unit_short_hour',
  ],
  'family': ['leave_confirm_desc', 'leave_last_member_desc'],
  'routine': [
    'status_home', 'status_work', 'status_school', 'status_gym', 'status_transit', 'status_sleep', 'status_meal',
    'status_leisure', 'status_other',
  ],
  'dashboard': [
    'widget_my_status', 'widget_my_status_hint', 'widget_family_timeline', 'widget_family_timeline_hint',
    'widget_cashflow', 'widget_cashflow_hint', 'widget_family_list', 'widget_family_list_hint',
    'widget_next_workout', 'widget_next_workout_hint',
  ],
  'exercises.catalog': [
    'bench_press', 'incline_bench_press', 'dumbbell_bench_press', 'chest_fly', 'push_up', 'dips', 'pull_up',
    'lat_pulldown', 'barbell_row', 'dumbbell_row', 'seated_cable_row', 'deadlift', 'romanian_deadlift', 'back_squat',
    'front_squat', 'leg_press', 'lunge', 'leg_extension', 'leg_curl', 'calf_raise', 'hip_thrust', 'overhead_press',
    'dumbbell_shoulder_press', 'lateral_raise', 'face_pull', 'biceps_curl', 'hammer_curl', 'triceps_pushdown',
    'skull_crusher', 'plank', 'crunch', 'hanging_leg_raise', 'kettlebell_swing', 'burpee', 'running', 'brisk_walking',
    'stationary_bike', 'rowing_machine', 'elliptical', 'jump_rope', 'swimming', 'stretching', 'yoga',
  ],
  'places': ['err_name_req', 'err_country_req', 'err_city_req'],
  'goal': ['mode_lose', 'mode_maintain', 'mode_gain'],
  'work': [
    'kind_day', 'kind_general', 'kind_day_hint', 'kind_general_hint', 'add_kind_day', 'add_kind_general',
    'field_title', 'field_note', 'field_kind', 'field_date', 'event_created', 'event_edited', 'event_reopened',
    'event_deleted',
  ],
  'cats': [
    'level_1', 'level_2', 'level_3', 'per_100_g', 'per_100_ml', 'per_100_short_g', 'per_100_short_ml',
    'items_count.one', 'items_count.other',
  ],
  'nutrition': [
    'gap_weight', 'gap_height', 'gap_sex', 'gap_activity',
    'activity_sedentary', 'activity_light', 'activity_moderate', 'activity_active', 'activity_very_active',
    'copied.one', 'copied.other', 'missing_count.one', 'missing_count.other',
  ],
  'study': [
    'unit_percent', 'unit_pages', 'unit_tasks', 'unit_lessons', 'unit_chapters', 'unit_hours',
    'unit_short_percent', 'unit_short_pages', 'unit_short_tasks', 'unit_short_lessons', 'unit_short_chapters',
    'unit_short_hours', 'subtopics_count.one', 'subtopics_count.other', 'notes_count.one', 'notes_count.other',
  ],
  'stock': [
    'measure_g', 'measure_ml', 'measure_pcs', 'source_receipt', 'source_manual', 'source_cooked', 'reason_spoiled',
    'reason_leftovers', 'reason_other', 'move_eaten', 'move_cooked', 'move_waste', 'move_used', 'lots_count.one', 'lots_count.other',
    'receipt_stocked.one', 'receipt_stocked.other',
  ],
};

Set<String> _flatten(Map<String, dynamic> aJson, [String aPrefix = ''])
{
  final keys = <String>{};
  aJson.forEach((aKey, aValue)
  {
    final path = aPrefix.isEmpty ? aKey : '$aPrefix.$aKey';
    if (aValue is Map<String, dynamic>)
    {
      keys.addAll(_flatten(aValue, path));
    }
    else
    {
      keys.add(path);
    }
  });
  return keys;
}

Set<String> _loadKeys(String aLocale)
{
  final raw = File('assets/i18n/$aLocale.json').readAsStringSync();
  return _flatten(jsonDecode(raw) as Map<String, dynamic>);
}

Set<String> _keysUsedInCode()
{
  final pattern = RegExp(r"'([a-z_]+\.[A-Za-z_.]+)'\s*\.tr\(");
  final keys = <String>{};

  for (final entity in Directory('lib').listSync(recursive: true))
  {
    if (entity is File && entity.path.endsWith('.dart'))
    {
      for (final match in pattern.allMatches(entity.readAsStringSync()))
      {
        keys.add(match.group(1)!);
      }
    }
  }

  dynamicKeys.forEach((aPrefix, aSuffixes)
  {
    keys.addAll(aSuffixes.map((aSuffix) => '$aPrefix.$aSuffix'));
  });

  return keys;
}

void main()
{
  final reference = _loadKeys('en');

  test('every key used in code exists in the reference locale', ()
  {
    final missing = _keysUsedInCode().difference(reference);
    expect(missing, isEmpty, reason: 'missing in en.json: $missing');
  });

  for (final locale in locales.where((aLocale) => aLocale != 'en'))
  {
    test('$locale.json has exactly the same keys as en.json', ()
    {
      final keys = _loadKeys(locale);
      expect(reference.difference(keys), isEmpty, reason: 'missing in $locale');
      expect(keys.difference(reference), isEmpty, reason: 'extra in $locale');
    });
  }
}
