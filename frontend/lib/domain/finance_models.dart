double parseDecimal(Object? aValue)
{
  return switch (aValue)
  {
    num value => value.toDouble(),
    String value => double.tryParse(value) ?? 0,
    _ => 0,
  };
}

double? parseDecimalOrNull(Object? aValue) => aValue == null ? null : parseDecimal(aValue);

DateTime parseTs(Object? aValue) => DateTime.parse(aValue as String).toLocal();

DateTime? parseTsOrNull(Object? aValue) => aValue == null ? null : parseTs(aValue);

String moneyWire(double aValue) => aValue.toStringAsFixed(2);

enum TxCategory
{
  groceries,
  restaurants,
  transport,
  fuel,
  shopping,
  health,
  utilities,
  entertainment,
  travel,
  education,
  home,
  cash,
  transfer,
  fees,
  income,
  other;

  static TxCategory? parse(Object? aValue)
  {
    for (final category in TxCategory.values)
    {
      if (category.name == aValue)
      {
        return category;
      }
    }
    return null;
  }
}

enum ItemKind
{
  product,
  service,
  food;

  static ItemKind parse(Object? aValue)
  {
    for (final kind in ItemKind.values)
    {
      if (kind.name == aValue)
      {
        return kind;
      }
    }
    return ItemKind.product;
  }
}

enum ItemUnit
{
  piece('piece'),
  kilogram('kilogram'),
  liter('liter'),
  meter('meter'),
  squareMeter('square_meter'),
  hour('hour');

  final String wire;

  const ItemUnit(this.wire);

  static ItemUnit parse(Object? aValue)
  {
    for (final unit in ItemUnit.values)
    {
      if (unit.wire == aValue)
      {
        return unit;
      }
    }
    return ItemUnit.piece;
  }
}

class DictItemDto
{
  final String id;
  final String name;
  final ItemKind kind;
  final ItemUnit unit;
  final bool isCustom;

  const DictItemDto({
    required this.id,
    required this.name,
    required this.kind,
    required this.unit,
    required this.isCustom,
  });

  factory DictItemDto.fromJson(Map<String, dynamic> aJson) => DictItemDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        kind: ItemKind.parse(aJson['kind']),
        unit: ItemUnit.parse(aJson['unit']),
        isCustom: aJson['is_custom'] as bool? ?? false,
      );

  static Map<String, dynamic> payload(String aName, ItemKind aKind, ItemUnit aUnit) => {
        'name': aName,
        'kind': aKind.name,
        'unit': aUnit.wire,
      };
}

class ItemPriceDto
{
  final String? merchantName;
  final String currCode;
  final double lastPrice;
  final double minPrice;
  final double avgPrice;
  final int purchaseCount;
  final DateTime lastTs;

  const ItemPriceDto({
    this.merchantName,
    required this.currCode,
    required this.lastPrice,
    required this.minPrice,
    required this.avgPrice,
    required this.purchaseCount,
    required this.lastTs,
  });

  factory ItemPriceDto.fromJson(Map<String, dynamic> aJson) => ItemPriceDto(
        merchantName: aJson['merchant_name'] as String?,
        currCode: aJson['curr_code'] as String,
        lastPrice: parseDecimal(aJson['last_price']),
        minPrice: parseDecimal(aJson['min_price']),
        avgPrice: parseDecimal(aJson['avg_price']),
        purchaseCount: (aJson['purchase_count'] as num).toInt(),
        lastTs: parseTs(aJson['last_ts']),
      );
}

enum StatsBucket { hour, day }

class BankConnDto
{
  final String id;
  final String provider;
  final String? aspspName;
  final String status;
  final DateTime? validUntil;
  final DateTime? lastSyncTs;
  final DateTime? nextSyncTs;
  final String? lastError;
  final int accountCount;

  const BankConnDto({
    required this.id,
    required this.provider,
    this.aspspName,
    required this.status,
    this.validUntil,
    this.lastSyncTs,
    this.nextSyncTs,
    this.lastError,
    required this.accountCount,
  });

  bool get isActive => status == 'active';

  factory BankConnDto.fromJson(Map<String, dynamic> aJson) => BankConnDto(
        id: aJson['id'] as String,
        provider: aJson['provider'] as String,
        aspspName: aJson['aspsp_name'] as String?,
        status: aJson['status'] as String,
        validUntil: parseTsOrNull(aJson['valid_until']),
        lastSyncTs: parseTsOrNull(aJson['last_sync_ts']),
        nextSyncTs: parseTsOrNull(aJson['next_sync_ts']),
        lastError: aJson['last_error'] as String?,
        accountCount: (aJson['account_count'] as num?)?.toInt() ?? 0,
      );
}

class AspspDto
{
  final String name;
  final String country;

  const AspspDto({required this.name, required this.country});

  factory AspspDto.fromJson(Map<String, dynamic> aJson) => AspspDto(
        name: aJson['name'] as String,
        country: aJson['country'] as String,
      );
}

class TxDto
{
  final String id;
  final String accountId;
  final String accountName;
  final String currCode;
  final double amount;
  final double? opAmount;
  final String? opCurrCode;
  final DateTime txTs;
  final String txType;
  final String source;
  final String? description;
  final String? counterparty;
  final TxCategory? category;
  final String? merchantId;
  final String? merchantName;
  final int? mcc;
  final String? note;
  final bool isPending;
  final String? transferId;
  final String? receiptId;
  final bool isEditable;

  const TxDto({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.currCode,
    required this.amount,
    this.opAmount,
    this.opCurrCode,
    required this.txTs,
    required this.txType,
    required this.source,
    this.description,
    this.counterparty,
    this.category,
    this.merchantId,
    this.merchantName,
    this.mcc,
    this.note,
    required this.isPending,
    this.transferId,
    this.receiptId,
    required this.isEditable,
  });

  bool get isTransfer => transferId != null;
  bool get isManual => source == 'manual';
  bool get isReceiptCash => source == 'receipt_cash';
  bool get isOutflow => amount < 0;

  String get title => merchantName ?? counterparty ?? description ?? note ?? accountName;

  factory TxDto.fromJson(Map<String, dynamic> aJson) => TxDto(
        id: aJson['id'] as String,
        accountId: aJson['account_id'] as String,
        accountName: aJson['account_name'] as String? ?? '',
        currCode: aJson['curr_code'] as String? ?? '',
        amount: parseDecimal(aJson['amount']),
        opAmount: parseDecimalOrNull(aJson['op_amount']),
        opCurrCode: aJson['op_curr_code'] as String?,
        txTs: parseTs(aJson['tx_ts']),
        txType: aJson['tx_type'] as String? ?? 'expense',
        source: aJson['source'] as String? ?? 'manual',
        description: aJson['description'] as String?,
        counterparty: aJson['counterparty'] as String?,
        category: TxCategory.parse(aJson['category']),
        merchantId: aJson['merchant_id'] as String?,
        merchantName: aJson['merchant_name'] as String?,
        mcc: (aJson['mcc'] as num?)?.toInt(),
        note: aJson['note'] as String?,
        isPending: aJson['is_pending'] as bool? ?? false,
        transferId: aJson['transfer_id'] as String?,
        receiptId: aJson['receipt_id'] as String?,
        isEditable: aJson['is_editable'] as bool? ?? false,
      );
}

class TxPage
{
  final List<TxDto> items;
  final String? nextCursor;

  const TxPage({required this.items, this.nextCursor});

  factory TxPage.fromJson(Map<String, dynamic> aJson) => TxPage(
        items: (aJson['items'] as List? ?? const [])
            .map((aItem) => TxDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        nextCursor: aJson['next_cursor'] as String?,
      );
}

class ReceiptItem
{
  final String itemId;
  final String name;
  final ItemKind kind;
  final ItemUnit unit;
  final double qty;
  final double? unitPrice;
  final double amount;

  const ReceiptItem({
    required this.itemId,
    this.name = '',
    this.kind = ItemKind.product,
    this.unit = ItemUnit.piece,
    this.qty = 1,
    this.unitPrice,
    required this.amount,
  });

  factory ReceiptItem.fromJson(Map<String, dynamic> aJson) => ReceiptItem(
        itemId: aJson['item_id'] as String,
        name: aJson['name'] as String? ?? '',
        kind: ItemKind.parse(aJson['kind']),
        unit: ItemUnit.parse(aJson['unit']),
        qty: parseDecimal(aJson['qty']),
        unitPrice: parseDecimalOrNull(aJson['unit_price']),
        amount: parseDecimal(aJson['amount']),
      );

  Map<String, dynamic> toJson() => {
        'item_id': itemId,
        'qty': qty.toStringAsFixed(3),
        'unit_price': unitPrice == null ? null : moneyWire(unitPrice!),
        'amount': moneyWire(amount),
      };
}

class ReceiptDto
{
  final String id;
  final DateTime receiptTs;
  final String? merchantId;
  final String? merchantName;
  final String? placeId;
  final String? placeName;
  final String currId;
  final String currCode;
  final String? cashAccountId;
  final String? note;
  final List<ReceiptItem> items;
  final List<TxDto> txs;
  final double itemsTotal;
  final double paidTotal;
  final double restAmount;
  final double cashAmount;

  const ReceiptDto({
    required this.id,
    required this.receiptTs,
    this.merchantId,
    this.merchantName,
    this.placeId,
    this.placeName,
    required this.currId,
    required this.currCode,
    this.cashAccountId,
    this.note,
    required this.items,
    required this.txs,
    required this.itemsTotal,
    required this.paidTotal,
    required this.restAmount,
    required this.cashAmount,
  });

  factory ReceiptDto.fromJson(Map<String, dynamic> aJson) => ReceiptDto(
        id: aJson['id'] as String,
        receiptTs: parseTs(aJson['receipt_ts']),
        merchantId: aJson['merchant_id'] as String?,
        merchantName: aJson['merchant_name'] as String?,
        placeId: aJson['place_id'] as String?,
        placeName: aJson['place_name'] as String?,
        currId: aJson['curr_id'] as String,
        currCode: aJson['curr_code'] as String? ?? '',
        cashAccountId: aJson['cash_account_id'] as String?,
        note: aJson['note'] as String?,
        items: (aJson['items'] as List? ?? const [])
            .map((aItem) => ReceiptItem.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        txs: (aJson['txs'] as List? ?? const [])
            .map((aItem) => TxDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        itemsTotal: parseDecimal(aJson['items_total']),
        paidTotal: parseDecimal(aJson['paid_total']),
        restAmount: parseDecimal(aJson['rest_amount']),
        cashAmount: parseDecimal(aJson['cash_amount']),
      );
}

class ReceiptListItem
{
  final String id;
  final DateTime receiptTs;
  final String? merchantName;
  final String? placeName;
  final String currCode;
  final double itemsTotal;
  final int itemCount;
  final int txCount;

  const ReceiptListItem({
    required this.id,
    required this.receiptTs,
    this.merchantName,
    this.placeName,
    required this.currCode,
    required this.itemsTotal,
    required this.itemCount,
    required this.txCount,
  });

  factory ReceiptListItem.fromJson(Map<String, dynamic> aJson) => ReceiptListItem(
        id: aJson['id'] as String,
        receiptTs: parseTs(aJson['receipt_ts']),
        merchantName: aJson['merchant_name'] as String?,
        placeName: aJson['place_name'] as String?,
        currCode: aJson['curr_code'] as String? ?? '',
        itemsTotal: parseDecimal(aJson['items_total']),
        itemCount: (aJson['item_count'] as num?)?.toInt() ?? 0,
        txCount: (aJson['tx_count'] as num?)?.toInt() ?? 0,
      );
}

class CashflowPoint
{
  final DateTime ts;
  final double income;
  final double expense;

  const CashflowPoint({required this.ts, required this.income, required this.expense});

  factory CashflowPoint.fromJson(Map<String, dynamic> aJson) => CashflowPoint(
        ts: parseTs(aJson['ts']),
        income: parseDecimal(aJson['income']),
        expense: parseDecimal(aJson['expense']),
      );
}

class CashflowSeries
{
  final String currCode;
  final double incomeTotal;
  final double expenseTotal;
  final List<CashflowPoint> points;

  const CashflowSeries({
    required this.currCode,
    required this.incomeTotal,
    required this.expenseTotal,
    required this.points,
  });

  factory CashflowSeries.fromJson(Map<String, dynamic> aJson) => CashflowSeries(
        currCode: aJson['curr_code'] as String? ?? '',
        incomeTotal: parseDecimal(aJson['income_total']),
        expenseTotal: parseDecimal(aJson['expense_total']),
        points: (aJson['points'] as List? ?? const [])
            .map((aItem) => CashflowPoint.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class MerchantDto
{
  final String id;
  final String name;

  const MerchantDto({required this.id, required this.name});

  factory MerchantDto.fromJson(Map<String, dynamic> aJson) => MerchantDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
      );
}
