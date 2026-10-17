import 'package:family_routine/domain/models.dart';
import 'package:family_routine/ui/finance/receipt_merge.dart';
import 'package:flutter_test/flutter_test.dart';

RecognizedLine _line(String aText, double aQty, double aAmount, {double? aPrice, int? aRef}) => RecognizedLine.fromJson({
      'text': aText,
      'name': aText,
      'kind': 'food',
      'unit': 'piece',
      'qty': '$aQty',
      'unit_price': aPrice?.toString(),
      'amount': '$aAmount',
      'match_kind': 'new',
      'entered_ref': aRef,
    });

void main()
{
  test('receipt lines go to entered rows, the rest are added and unmatched rows are reported', ()
  {
    final plan = ReceiptMergePlan.of(4, [
      _line('МОЛ ПРОСТ', 2, 85.8, aRef: 0),
      _line('КАВА', 1, 195.3, aRef: 1),
      _line('ПАКЕТ', 1, 2.5),
      _line('КАВА', 1, 195.3, aRef: 1),
      _line('ХЛІБ', 1, 30, aRef: 9),
    ]);

    expect(plan.linked.keys, [0, 1]);
    expect(plan.linked[1]!.length, 2);
    expect(plan.linkedLines, 3);
    expect(plan.added.map((aLine) => aLine.text), ['ПАКЕТ', 'ХЛІБ']);
    expect(plan.missing, [2, 3]);
  });

  test('repeated lines of one product are summed', ()
  {
    final same = ReceiptLineSum.of([_line('КАВА', 1, 195.3, aPrice: 195.3), _line('КАВА', 2, 390.6, aPrice: 195.3)]);
    expect(same.qty, 3);
    expect(same.amount, closeTo(585.9, 1e-9));
    expect(same.unitPrice, 195.3);
    expect(same.text, 'КАВА');

    final discounted = ReceiptLineSum.of([_line('ЧАЙ', 1, 40, aPrice: 40), _line('ЧАЙ', 1, 30, aPrice: 30)]);
    expect(discounted.amount, 70);
    expect(discounted.unitPrice, 35);

    final single = ReceiptLineSum.of([_line('БАНАНИ', 1.235, 61.2)]);
    expect(single.unitPrice, isNull);
    expect(single.qty, 1.235);
  });

  test('recognized lines keep the entered row they belong to', ()
  {
    expect(_line('КАВА', 1, 1, aRef: 3).enteredRef, 3);
    expect(_line('КАВА', 1, 1).enteredRef, isNull);
  });
}
