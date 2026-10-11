const Set<int> _gtinLengths = {8, 12, 13, 14};

String normalizeBarcode(String aValue) => aValue.replaceAll(RegExp(r'[\s-]'), '');

bool isValidGtin(String aValue)
{
  final digits = normalizeBarcode(aValue);
  if (!_gtinLengths.contains(digits.length) || !RegExp(r'^[0-9]+$').hasMatch(digits))
  {
    return false;
  }

  final values = digits.split('').map(int.parse).toList();
  final check = values.removeLast();
  var sum = 0;
  for (var index = 0; index < values.length; index++)
  {
    final digit = values[values.length - 1 - index];
    sum += index.isEven ? digit * 3 : digit;
  }
  return (10 - sum % 10) % 10 == check;
}
