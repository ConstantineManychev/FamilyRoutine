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
    test('bank wallet carries connection and decimal balance', ()
    {
      final wallet = AccountDto.fromJson({
        'id': 'w1',
        'user_id': 'u1',
        'family_id': null,
        'curr_id': 'c1',
        'curr_code': 'UAH',
        'account_type': 'card',
        'bank_type': 'monobank',
        'name': 'Mono',
        'mask': '1234',
        'conn_id': 'conn1',
        'provider': 'monobank',
        'balance': '1500.50',
        'balance_ts': '2026-10-10T10:00:00Z',
        'is_active': true,
        'is_editable': true,
      });

      expect(wallet.isLinked, isTrue);
      expect(wallet.balance, 1500.5);
      expect(wallet.isPersonal, isTrue);
      expect(wallet.isCash, isFalse);
    });

    test('transaction parses decimals, category and links', ()
    {
      final tx = TxDto.fromJson({
        'id': 't1',
        'account_id': 'a1',
        'account_name': 'Mono',
        'curr_code': 'UAH',
        'amount': '-125.50',
        'op_amount': '-3.00',
        'op_curr_code': 'USD',
        'tx_ts': '2026-10-10T10:00:00Z',
        'tx_type': 'expense',
        'source': 'bank',
        'description': 'Silpo',
        'category': 'groceries',
        'merchant_name': 'Сільпо',
        'is_pending': false,
        'receipt_id': 'r1',
        'is_editable': true,
      });

      expect(tx.amount, -125.5);
      expect(tx.opAmount, -3.0);
      expect(tx.category, TxCategory.groceries);
      expect(tx.title, 'Сільпо');
      expect(tx.isOutflow, isTrue);
      expect(tx.isTransfer, isFalse);
    });

    test('receipt item references the dictionary and serializes money with two decimals', ()
    {
      final item = ReceiptItem.fromJson({
        'item_id': 'i1',
        'name': 'Яблоки',
        'kind': 'product',
        'unit': 'kilogram',
        'qty': '2.500',
        'unit_price': '40.00',
        'amount': '100.00',
      });
      expect(item.unit, ItemUnit.kilogram);
      expect(item.toJson(), {'item_id': 'i1', 'qty': '2.500', 'unit_price': '40.00', 'amount': '100.00'});
    });

    test('transfer peer and category stats parse', ()
    {
      final tx = TxDto.fromJson({
        'id': 't1',
        'account_id': 'a1',
        'account_name': 'Mono EUR',
        'curr_code': 'EUR',
        'amount': '-100.00',
        'tx_ts': '2026-10-09T10:00:00Z',
        'tx_type': 'transfer',
        'source': 'bank',
        'transfer_id': 'tr1',
        'is_editable': true,
        'is_auto_transfer': true,
        'peer_account_name': 'Mono UAH',
        'peer_amount': '4550.00',
        'peer_curr_code': 'UAH',
        'similar_key': null,
      });
      expect(tx.isTransfer, isTrue);
      expect(tx.isAutoTransfer, isTrue);
      expect(tx.peerAmount, 4550);

      final stats = CategoryStats.fromJson({
        'series': [
          {
            'curr_code': 'EUR',
            'income_total': '0.00',
            'expense_total': '30.00',
            'items': [
              {'category': 'groceries', 'income': '0.00', 'expense': '20.00', 'tx_count': 2},
              {'category': null, 'income': '0.00', 'expense': '10.00', 'tx_count': 1},
            ],
          },
        ],
        'missing_rates': ['UAH'],
      });
      expect(stats.series.single.items.first.category, TxCategory.groceries);
      expect(stats.series.single.items.last.category, isNull);
      expect(stats.missingRates, ['UAH']);
    });

    test('dictionary item and price stats parse', ()
    {
      final item = DictItemDto.fromJson({'id': 'i1', 'name': 'Плитка', 'kind': 'product', 'unit': 'square_meter', 'is_custom': true});
      expect(item.unit, ItemUnit.squareMeter);
      expect(DictItemDto.payload('Плитка', ItemKind.service, ItemUnit.hour), {'name': 'Плитка', 'kind': 'service', 'unit': 'hour'});

      final price = ItemPriceDto.fromJson({
        'merchant_name': null,
        'curr_code': 'UAH',
        'last_price': '32.00',
        'min_price': '30.00',
        'avg_price': '31.00',
        'purchase_count': 2,
        'last_ts': '2026-10-09T10:00:00Z',
      });
      expect(price.merchantName, isNull);
      expect(price.minPrice, 30);
      expect(price.purchaseCount, 2);
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

    test('only the owner may remove admins and nobody may remove the owner', ()
    {
      FamDetailDto detail(String aMyRole, bool aIsOwner) => FamDetailDto.fromJson({
            'id': 'f1',
            'name': 'Home',
            'my_role': aMyRole,
            'is_owner': aIsOwner,
            'members': [
              {'id': 'o', 'first_name': 'O', 'last_name': 'O', 'role': 'admin', 'is_owner': true},
              {'id': 'a', 'first_name': 'A', 'last_name': 'A', 'role': 'admin', 'is_owner': false},
              {'id': 's', 'first_name': 'S', 'last_name': 'S', 'role': 'standard', 'is_owner': false},
            ],
          });

      final asOwner = detail('admin', true);
      final asAdmin = detail('admin', false);
      final asStandard = detail('standard', false);
      final [owner, admin, standard] = asOwner.members;

      expect(owner.isAdmin, isTrue);
      expect([asOwner.canRemove(owner), asOwner.canRemove(admin), asOwner.canRemove(standard)], [false, true, true]);
      expect([asAdmin.canRemove(owner), asAdmin.canRemove(admin), asAdmin.canRemove(standard)], [false, false, true]);
      expect(asStandard.members.any(asStandard.canRemove), isFalse);
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
