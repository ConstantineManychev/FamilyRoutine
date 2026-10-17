import '../../domain/models.dart';

const double _priceTolerance = 0.005;

double _cents(double aValue) => (aValue * 100).roundToDouble() / 100;

class ReceiptLineSum
{
  final String text;
  final double qty;
  final double? unitPrice;
  final double amount;

  const ReceiptLineSum({required this.text, required this.qty, this.unitPrice, required this.amount});

  factory ReceiptLineSum.of(List<RecognizedLine> aLines)
  {
    final qty = aLines.fold<double>(0, (aSum, aLine) => aSum + aLine.qty);
    final amount = _cents(aLines.fold<double>(0, (aSum, aLine) => aSum + aLine.amount));
    final prices = aLines.map((aLine) => aLine.unitPrice).toList();
    final first = prices.first;
    final isSamePrice = first != null && prices.every((aPrice) => aPrice != null && (aPrice - first).abs() < _priceTolerance);
    final unitPrice = aLines.length == 1
        ? first
        : isSamePrice
            ? first
            : qty > 0
                ? _cents(amount / qty)
                : null;
    return ReceiptLineSum(text: aLines.first.text, qty: qty, unitPrice: unitPrice, amount: amount);
  }
}

class ReceiptMergePlan
{
  final Map<int, List<RecognizedLine>> linked;
  final List<RecognizedLine> added;
  final List<int> missing;

  const ReceiptMergePlan({required this.linked, required this.added, required this.missing});

  factory ReceiptMergePlan.of(int aEnteredCount, List<RecognizedLine> aLines)
  {
    final linked = <int, List<RecognizedLine>>{};
    final added = <RecognizedLine>[];
    for (final line in aLines)
    {
      final ref = line.enteredRef;
      if (ref != null && ref >= 0 && ref < aEnteredCount)
      {
        linked.putIfAbsent(ref, () => []).add(line);
      }
      else
      {
        added.add(line);
      }
    }
    final missing = [
      for (var index = 0; index < aEnteredCount; index++)
        if (!linked.containsKey(index)) index,
    ];
    return ReceiptMergePlan(linked: linked, added: added, missing: missing);
  }

  int get linkedLines => linked.values.fold(0, (aSum, aLines) => aSum + aLines.length);
}
