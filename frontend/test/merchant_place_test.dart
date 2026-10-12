import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/finance/merchant_place_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

PlaceDto _place(String aName, List<Map<String, dynamic>> aAddrs) => PlaceDto.fromJson({
      'id': aName,
      'name': aName,
      'addrs': aAddrs,
    });

void main()
{
  group('merchant places', ()
  {
    test('suggested place name drops store numbers and shouting', ()
    {
      expect(suggestPlaceName('LIDL 0907 ATHL'), 'Lidl');
      expect(suggestPlaceName('Lidl'), 'Lidl');
      expect(suggestPlaceName('Сільпо'), 'Сільпо');
      expect(suggestPlaceName('Novus Ukraine'), 'Novus Ukraine');
    });

    test('places and branches are suggested from bank names', ()
    {
      final lidl = _place('Lidl', [
        {'id': 'dublin', 'is_main': true, 'country_id': 'ie', 'city_id': 'd', 'label': 'Dublin, Main St 1'},
        {'id': 'athlone', 'is_main': false, 'country_id': 'ie', 'city_id': 'a', 'label': 'Athlone'},
      ]);
      final aldi = _place('Aldi', const []);

      expect(isSuggestedPlace(lidl, 'LIDL 0907 ATHL'), isTrue);
      expect(isSuggestedPlace(aldi, 'LIDL 0907 ATHL'), isFalse);
      expect(suggestBranch(lidl, 'LIDL 0907 ATHL'), 'athlone');
      expect(suggestBranch(lidl, 'Lidl'), isNull);
    });

    test('city-only addresses and bank names are parsed', ()
    {
      final place = PlaceDto.fromJson({
        'id': 'p1',
        'name': 'Lidl',
        'addrs': [
          {'id': 'a1', 'is_main': true, 'country_id': 'ie', 'city_id': 'c1', 'street_id': null, 'house_num': null, 'label': 'Athlone'},
        ],
        'merchants': [
          {'merchant_id': 'm1', 'name': 'LIDL 0907 ATHL', 'place_addr_id': 'a1'},
        ],
      });

      expect(place.addrs.single.streetId, isNull);
      expect(place.addrs.single.toJson(), {
        'id': 'a1',
        'is_main': true,
        'country_id': 'ie',
        'city_id': 'c1',
        'street_id': null,
        'house_num': null,
        'apt': null,
        'zip': null,
      });
      expect(place.merchants.single.name, 'LIDL 0907 ATHL');
      expect(place.merchants.single.placeAddrId, 'a1');
    });

    test('linked place names the transaction', ()
    {
      final tx = TxDto.fromJson({
        'id': 't1',
        'account_id': 'acc',
        'account_name': 'AIB',
        'curr_code': 'EUR',
        'amount': '-39.57',
        'tx_ts': '2026-09-28T13:00:00Z',
        'merchant_id': 'm1',
        'merchant_name': 'LIDL 0907 ATHL',
        'description': 'VDC-LIDL 0907 ATHL; Purchase',
        'place_id': 'p1',
        'place_name': 'Lidl',
        'branch': 'Athlone',
        'is_merchant_linked': true,
      });

      expect(tx.title, 'Lidl');
      expect(tx.placeLabel, 'Lidl · Athlone');
      expect(tx.isMerchantLinked, isTrue);
    });
  });
}
