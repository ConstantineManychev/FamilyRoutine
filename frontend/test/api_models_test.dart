import 'package:dio/dio.dart';
import 'package:family_routine/core/api_error.dart';
import 'package:family_routine/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _dioError(int? aStatus, Object? aData)
{
  final options = RequestOptions(path: '/api/test');
  return DioException(
    requestOptions: options,
    response: aStatus == null ? null : Response(requestOptions: options, statusCode: aStatus, data: aData),
  );
}

void main()
{
  group('ApiException.from', ()
  {
    test('reads machine readable code and field', ()
    {
      final error = ApiException.from(_dioError(400, {'code': 'VALIDATION', 'field': 'email'}));
      expect(error.code, 'VALIDATION');
      expect(error.field, 'email');
      expect(error.messageKey, 'errors.VALIDATION');
    });

    test('detects expired sessions', ()
    {
      expect(ApiException.from(_dioError(401, {'code': 'UNAUTHENTICATED'})).isUnauthenticated, isTrue);
    });

    test('maps transport failures to NETWORK', ()
    {
      expect(ApiException.from(_dioError(null, null)).code, ApiException.networkCode);
    });

    test('maps unexpected payloads to UNKNOWN', ()
    {
      expect(ApiException.from(_dioError(502, '<html>')).code, ApiException.unknownCode);
      expect(ApiException.from(StateError('x')).code, ApiException.unknownCode);
    });
  });

  group('models', ()
  {
    test('wallet exposes only the token flag', ()
    {
      final wallet = AccountDto.fromJson({
        'id': 'w1',
        'user_id': 'u1',
        'family_id': null,
        'curr_id': 'c1',
        'account_type': 'card',
        'bank_type': 'monobank',
        'name': 'Mono',
        'mask': '1234',
        'is_sync_token_set': true,
        'is_active': true,
        'is_editable': true,
      });

      expect(wallet.isSyncTokenSet, isTrue);
      expect(wallet.isPersonal, isTrue);
      expect(wallet.isEditable, isTrue);
    });

    test('family detail carries my role', ()
    {
      final fam = FamDetailDto.fromJson({
        'id': 'f1',
        'name': 'Home',
        'my_role': 'standard',
        'members': [
          {'id': 'u1', 'first_name': 'A', 'last_name': 'B', 'role': 'admin'},
        ],
      });

      expect(fam.isAdmin, isFalse);
      expect(fam.members.single.role, MemberRole.admin);
    });

    test('muscle groups use backend wire names', ()
    {
      const group = ExMuscGrpDto(grp: MuscGrpType.fullBody, pct: 50);
      expect(group.toJson(), {'grp': 'full_body', 'pct': 50.0});
      expect(ExMuscGrpDto.fromJson({'grp': 'full_body', 'pct': 10}).grp, MuscGrpType.fullBody);
    });

    test('place keeps existing address ids when saving', ()
    {
      final place = PlaceDto.fromJson({
        'id': 'p1',
        'name': 'Home',
        'addrs': [
          {
            'id': 'a2', 'is_main': false, 'country_id': 'c', 'city_id': 'ci', 'street_id': 's',
            'house_num': '1', 'zip': '0',
          },
          {
            'id': 'a1', 'is_main': true, 'country_id': 'c', 'city_id': 'ci', 'street_id': 's',
            'house_num': '2', 'zip': '0',
          },
        ],
      });

      expect(place.mainAddr?.id, 'a1');
      expect(place.addrs.first.toJson()['id'], 'a2');
    });
  });
}
