import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> locales = ['en', 'ru', 'de', 'fr', 'ja', 'zh'];

const Map<String, List<String>> dynamicKeys = {
  'errors': [
    'VALIDATION', 'UNAUTHENTICATED', 'INVALID_CREDENTIALS', 'FORBIDDEN', 'NOT_FOUND', 'ALREADY_EXISTS',
    'EMAIL_TAKEN', 'IN_USE', 'OWNER_PROTECTED', 'OWNER_MUST_TRANSFER', 'TOO_MANY_INVITES', 'TOO_MANY_REQUESTS',
    'INTERNAL', 'NETWORK', 'UNKNOWN',
  ],
  'family.roles': ['owner', 'admin', 'standard'],
  'wallet': ['type_cash', 'type_card', 'type_bank_acc', 'bank_monobank', 'bank_aib', 'bank_other'],
  'exercises.types': ['cardio', 'strength', 'flexibility', 'mixed'],
  'exercises.w_types': ['external', 'hybrid', 'bodyweight'],
  'exercises.muscle_grps': ['chest', 'back', 'legs', 'shoulders', 'arms', 'core', 'cardio', 'full_body'],
  'dicts': ['events', 'exercises', 'items'],
  'family': ['leave_confirm_desc', 'leave_last_member_desc'],
  'places': ['err_name_req', 'err_country_req', 'err_city_req', 'err_street_req', 'err_house_zip_req'],
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
