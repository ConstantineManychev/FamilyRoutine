import 'package:dio/dio.dart';
import 'package:family_routine/core/api_error.dart';
import 'package:family_routine/domain/barcode.dart';
import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/finance/wallet_scope.dart';
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

    test('timeline marks resolve the current status and dashboards skip unknown widgets', ()
    {
      final timeline = TimelineDto.fromJson({
        'family_id': 'f1',
        'family_name': 'Семья',
        'members': [
          {
            'user_id': 'u1',
            'first_name': 'Анна',
            'last_name': 'Тест',
            'is_me': true,
            'marks': [
              {'id': 'm1', 'status': 'work', 'note': null, 'start_ts': '2026-10-10T06:00:00Z', 'end_ts': '2026-10-10T10:00:00Z'},
              {'id': 'm2', 'status': 'meal', 'note': 'Обед', 'start_ts': '2026-10-10T10:00:00Z', 'end_ts': null},
            ],
          },
        ],
      });
      final member = timeline.members.single;
      expect(member.markAt(DateTime.utc(2026, 10, 10, 9, 59))?.status, RoutineStatus.work);
      expect(member.markAt(DateTime.utc(2026, 10, 10, 10))?.status, RoutineStatus.meal);
      expect(member.markAt(DateTime.utc(2026, 10, 10, 5)), isNull);
      expect(RoutineStatus.fromJson('teleport'), RoutineStatus.other);

      final dashboard = DashboardDto.fromJson({
        'id': 'd1',
        'name': 'Главная',
        'widgets': [
          {'id': 'w1', 'kind': 'family_timeline', 'family_id': 'f1', 'family_name': null, 'is_available': false},
          {'id': 'w2', 'kind': 'weather', 'family_id': null, 'family_name': null, 'is_available': true},
        ],
      });
      expect(dashboard.widgets.single.kind, WidgetKind.familyTimeline);
      expect(dashboard.widgets.single.isAvailable, isFalse);
    });

    test('dictionary item, owner, nutrition and price comparison parse', ()
    {
      final item = DictItemDto.fromJson({
        'id': 'i1',
        'name': 'Плитка',
        'kind': 'product',
        'unit': 'square_meter',
        'barcode': '4820024700016',
        'nutrition': null,
        'owner_kind': 'member',
        'owner_name': 'Анна Коваль',
        'is_editable': false,
        'is_in_use': false,
      });
      expect(item.unit, ItemUnit.squareMeter);
      expect(item.ownerKind, ItemOwnerKind.member);
      expect(item.ownerName, 'Анна Коваль');
      expect(item.nutrition.isEmpty, isTrue);
      expect(item.canEditIdentity, isFalse);

      final locked = DictItemDto.fromJson({
        'id': 'i2',
        'name': 'Молоко',
        'kind': 'food',
        'unit': 'liter',
        'nutrition': {'kcal': '52', 'prot': '2.8', 'fat': null, 'carb': '4.7'},
        'owner_kind': 'me',
        'is_editable': true,
        'is_in_use': true,
      });
      expect(locked.nutrition.kcal, 52);
      expect(locked.nutrition.fat, isNull);
      expect(locked.canEditIdentity, isFalse);
      expect(locked.canDelete, isFalse);
      final adminView = DictItemDto.fromJson({...{'id': 'i3', 'name': 'Сир', 'kind': 'food', 'unit': 'kilogram'}, 'owner_kind': 'user', 'is_editable': true, 'is_in_use': true});
      expect(adminView.isAdminEdit, isTrue);
      expect(adminView.canEditIdentity, isTrue);
      expect(adminView.canDelete, isFalse);

      expect(DictItemDto.payload('Плитка', ItemKind.service, ItemUnit.hour), {'name': 'Плитка', 'kind': 'service', 'unit': 'hour'});
      expect(
        DictItemDto.payload(
          'Кава',
          ItemKind.food,
          ItemUnit.piece,
          aBarcode: ' 4820024700016 ',
          aNutrition: const NutritionData(kcal: 2, fat: 0.1),
        ),
        {
          'name': 'Кава',
          'kind': 'food',
          'unit': 'piece',
          'barcode': '4820024700016',
          'nutrition': {'kcal': '2.0', 'prot': null, 'fat': '0.1', 'carb': null},
        },
      );

      final lookup = ProductLookup.fromJson({
        'status': 'found',
        'product': {
          'kind': 'food',
          'name': 'Кава мелена',
          'suggested_name': 'Кава мелена Jacobs 250 г',
          'barcode': '4820024700016',
          'nutrition': {'kcal': '2'},
        },
      });
      expect(lookup.status, LookupStatus.found);
      expect(lookup.product!.bestName, 'Кава мелена Jacobs 250 г');
      expect(ProductLookup.fromJson({'status': 'not_found', 'product': null}).status, LookupStatus.notFound);

      final point = PricePoint.fromJson({
        'ts': '2026-10-01T10:00:00Z',
        'unit_price': '180.00',
        'qty': '2',
        'curr_id': 'c1',
        'curr_code': 'UAH',
        'place_id': 'p1',
        'store_name': 'Сільпо',
        'branch': 'Київ, Хрещатик 5',
        'source': 'manual',
        'is_shared': false,
      });
      expect(point.unitPrice, 180);
      expect(point.isManual, isTrue);

      final data = ItemPricesData.fromJson({
        'prices': [
          {
            'store_name': 'АТБ',
            'branch': 'Київ, Хрещатик 5',
            'curr_code': 'UAH',
            'last_price': '32.00',
            'min_price': '30.00',
            'avg_price': '31.00',
            'count': 2,
            'last_ts': '2026-10-09T10:00:00Z',
            'is_shared': true,
          },
        ],
        'missing_rates': ['EUR'],
      });
      final price = data.prices.single;
      expect(price.branch, 'Київ, Хрещатик 5');
      expect(price.minPrice, 30);
      expect(price.count, 2);
      expect(price.isShared, isTrue);
      expect(data.missingRates, ['EUR']);

      final manual = ManualPriceDto.fromJson({
        'id': 'p1',
        'store_name': 'Tesco',
        'curr_code': 'EUR',
        'qty': '2.000',
        'price': '10.00',
        'seen_ts': '2026-10-09T10:00:00Z',
      });
      expect(manual.unitPrice, 5);
    });

    test('recognized receipt keeps matches, new items and the place proposal', ()
    {
      final draft = RecognizedReceipt.fromJson({
        'receipt_ts': '2026-10-10T21:15:00Z',
        'curr_id': 'c1',
        'curr_code': 'UAH',
        'total': '300.50',
        'lines_total': '298.00',
        'store_name': 'Новус',
        'place_id': null,
        'new_place': {'place_id': null, 'name': 'Новус', 'city': 'Київ', 'street': 'Велика Васильківська', 'house_num': '72'},
        'lines': [
          {'text': 'ХЛІБ', 'name': 'Хліб', 'kind': 'food', 'unit': 'piece', 'qty': '1', 'amount': '30.00', 'item_id': 'i1', 'item_name': 'Хліб білий', 'match_kind': 'similar'},
          {'text': 'БАНАНИ ВАГ', 'name': 'Банани', 'kind': 'food', 'unit': 'kilogram', 'qty': '1.235', 'amount': '61.20', 'match_kind': 'new'},
        ],
      });
      expect(draft.isTotalMismatch, isTrue);
      expect(draft.newPlace!.isBranch, isFalse);
      expect(draft.newPlace!.address, 'Київ, Велика Васильківська 72');
      expect(draft.lines.first.match, LineMatch.similar);
      expect(draft.lines.last.match, LineMatch.isNew);
      expect(draft.lines.last.unit, ItemUnit.kilogram);
      expect(
        const NewItemDraft(name: 'Банани', kind: ItemKind.food, unit: ItemUnit.kilogram).toJson(),
        {'name': 'Банани', 'kind': 'food', 'unit': 'kilogram'},
      );
    });

    test('ai settings expose keys, server limits and usage of the active source', ()
    {
      final settings = AiSettings.fromJson({
        'source': 'openai',
        'daily_limit': 5,
        'monthly_limit': null,
        'effective_daily_limit': 5,
        'effective_monthly_limit': 300,
        'server': {'provider': 'anthropic', 'model': 'claude-opus-5-5', 'daily_limit': 30, 'monthly_limit': 300},
        'is_own_keys_allowed': true,
        'keys': [
          {'provider': 'openai', 'key_hint': 'cdef', 'model': 'gpt-5.5', 'updated_ts': '2026-10-11T10:00:00Z'},
        ],
        'usage': [
          {'is_own_key': false, 'today_count': 1, 'month_count': 4, 'month_input_tokens': 10, 'month_output_tokens': 5},
          {'is_own_key': true, 'today_count': 2, 'month_count': 7, 'month_input_tokens': 2200, 'month_output_tokens': 700},
        ],
      });
      expect(settings.source.ownProvider, AiProvider.openai);
      expect(settings.keyOf(AiProvider.openai)?.keyHint, 'cdef');
      expect(settings.keyOf(AiProvider.gemini), isNull);
      expect(settings.server?.provider.label, 'Anthropic (Claude)');
      expect(settings.currentUsage.monthCount, 7);
      expect(AiSource.fromProvider(AiProvider.gemini).toJson(), 'gemini');

      final features = AiFeatures.fromJson({'is_receipt_recognition': true, 'recognition_provider': 'gemini'});
      expect(features.provider?.product, 'Gemini');
      expect(AiFeatures.fromJson({'is_receipt_recognition': false, 'recognition_provider': null}).provider, isNull);
    });

    test('barcodes need a valid GTIN check digit', ()
    {
      expect(isValidGtin('4820024700016'), isTrue);
      expect(isValidGtin('4820024700017'), isFalse);
      expect(isValidGtin('036000291452'), isTrue);
      expect(isValidGtin('96385074'), isTrue);
      expect(isValidGtin('123'), isFalse);
      expect(normalizeBarcode(' 4006381-333931 '), '4006381333931');
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

    test('receipt discount is part of the paid total', ()
    {
      final draft = RecognizedReceipt.fromJson({
        'lines_total': '13.45',
        'discount': '5.00',
        'total': 8.45,
        'lines': const [],
      });
      expect(draft.payable, closeTo(8.45, 1e-9));
      expect(draft.isTotalMismatch, isFalse);

      final unpaid = RecognizedReceipt.fromJson({'lines_total': '13.45', 'total': 8.45, 'lines': const []});
      expect(unpaid.discount, 0);
      expect(unpaid.isTotalMismatch, isTrue);
    });

    test('shared wallet keeps its owner and wallet scope encodes owner filters', ()
    {
      final wallet = AccountDto.fromJson({
        'id': 'w2',
        'user_id': 'u2',
        'family_id': null,
        'curr_id': 'c1',
        'curr_code': 'EUR',
        'account_type': 'card',
        'name': 'AIB',
        'is_active': true,
        'is_editable': false,
        'is_own': false,
        'owner_name': 'Boris Petrov',
        'shared_family_ids': const [],
      });
      expect(wallet.isOwn, isFalse);
      expect(wallet.isOwnPersonal, isFalse);
      expect(walletLabel(wallet), 'AIB · Boris');

      final byOwner = WalletScope.of(aOwnerId: 'u2');
      expect(byOwner.ownerId, 'u2');
      expect(byOwner.accountId, isNull);
      expect(byOwner.query, {'owner_id': 'u2'});
      expect(WalletScope(byOwner.value).ownerId, 'u2');
      expect(WalletScope.of(aAccountId: 'w2').query, {'account_id': 'w2'});
      expect(const WalletScope(null).query, isEmpty);
    });

    test('shared receipt list item names its owner', ()
    {
      final receipt = ReceiptListItem.fromJson({
        'id': 'r1',
        'receipt_ts': '2026-10-10T10:00:00Z',
        'curr_code': 'EUR',
        'items_total': '10.00',
        'discount': '0',
        'item_count': 1,
        'tx_count': 1,
        'owner_name': 'Boris Petrov',
      });
      expect(receipt.ownerName, 'Boris Petrov');
    });

    test('balance document separates opening records from differences', ()
    {
      final opening = BalanceDoc.fromJson({
        'id': 'd1',
        'account_id': 'w1',
        'balance_ts': '2026-10-10T10:00:00Z',
        'amount': '70.00',
        'prev_ts': null,
        'expected': null,
        'delta': null,
        'write_offs': const [],
      });
      expect(opening.isInitial, isTrue);
      expect(opening.hasDelta, isFalse);

      final checked = BalanceDoc.fromJson({
        'id': 'd2',
        'account_id': 'w1',
        'balance_ts': '2026-10-12T10:00:00Z',
        'amount': '50.00',
        'prev_ts': '2026-10-10T10:00:00Z',
        'expected': '65.00',
        'delta': '-15.00',
        'write_offs': [
          {'id': 't1', 'balance_doc_id': 'd2', 'tx_ts': '2026-10-11T10:00:00Z', 'amount': '-10.00', 'category': 'groceries', 'note': null},
        ],
      });
      expect(checked.isInitial, isFalse);
      expect(checked.hasDelta, isTrue);
      expect(checked.delta, -15);
      expect(checked.writeOffs.single.category, TxCategory.groceries);
      expect(BalanceDoc.fromJson({'id': 'd3', 'balance_ts': '2026-10-12T10:00:00Z', 'amount': '1', 'prev_ts': '2026-10-11T10:00:00Z', 'delta': '0.00'}).hasDelta, isFalse);
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
