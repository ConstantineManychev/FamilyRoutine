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
  final String? barcode;
  final bool isCustom;
  final String? familyId;
  final String? familyName;
  final bool isEditable;

  const DictItemDto({
    required this.id,
    required this.name,
    required this.kind,
    required this.unit,
    this.barcode,
    required this.isCustom,
    this.familyId,
    this.familyName,
    this.isEditable = false,
  });

  bool get isPersonal => isCustom && familyId == null;

  factory DictItemDto.fromJson(Map<String, dynamic> aJson) => DictItemDto(
        id: aJson['id'] as String,
        name: aJson['name'] as String,
        kind: ItemKind.parse(aJson['kind']),
        unit: ItemUnit.parse(aJson['unit']),
        barcode: aJson['barcode'] as String?,
        isCustom: aJson['is_custom'] as bool? ?? false,
        familyId: aJson['family_id'] as String?,
        familyName: aJson['family_name'] as String?,
        isEditable: aJson['is_editable'] as bool? ?? false,
      );

  static Map<String, dynamic> payload(
    String aName,
    ItemKind aKind,
    ItemUnit aUnit,
    {
      String? aBarcode,
      String? aFamilyId,
    }
  ) => {
        'name': aName,
        'kind': aKind.name,
        'unit': aUnit.wire,
        if (aBarcode != null && aBarcode.trim().isNotEmpty) 'barcode': aBarcode.trim(),
        if (aFamilyId != null) 'family_id': aFamilyId,
      };
}

class ItemPriceDto
{
  final String? storeName;
  final String? branch;
  final String currCode;
  final double lastPrice;
  final double minPrice;
  final double avgPrice;
  final int count;
  final DateTime lastTs;
  final bool isShared;

  const ItemPriceDto({
    this.storeName,
    this.branch,
    required this.currCode,
    required this.lastPrice,
    required this.minPrice,
    required this.avgPrice,
    required this.count,
    required this.lastTs,
    this.isShared = false,
  });

  factory ItemPriceDto.fromJson(Map<String, dynamic> aJson) => ItemPriceDto(
        storeName: aJson['store_name'] as String?,
        branch: aJson['branch'] as String?,
        currCode: aJson['curr_code'] as String,
        lastPrice: parseDecimal(aJson['last_price']),
        minPrice: parseDecimal(aJson['min_price']),
        avgPrice: parseDecimal(aJson['avg_price']),
        count: (aJson['count'] as num).toInt(),
        lastTs: parseTs(aJson['last_ts']),
        isShared: aJson['is_shared'] as bool? ?? false,
      );
}

class ItemPricesData
{
  final List<ItemPriceDto> prices;
  final List<String> missingRates;
  final int matchedItems;

  const ItemPricesData({required this.prices, this.missingRates = const [], this.matchedItems = 1});

  factory ItemPricesData.fromJson(Map<String, dynamic> aJson) => ItemPricesData(
        prices: (aJson['prices'] as List? ?? const [])
            .map((aItem) => ItemPriceDto.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        missingRates: (aJson['missing_rates'] as List? ?? const []).cast<String>(),
        matchedItems: (aJson['matched_items'] as num?)?.toInt() ?? 1,
      );
}

class ManualPriceDto
{
  final String id;
  final String? placeId;
  final String? placeAddrId;
  final String? storeName;
  final String? branch;
  final String currCode;
  final double qty;
  final double price;
  final DateTime seenTs;
  final String? note;

  const ManualPriceDto({
    required this.id,
    this.placeId,
    this.placeAddrId,
    this.storeName,
    this.branch,
    required this.currCode,
    required this.qty,
    required this.price,
    required this.seenTs,
    this.note,
  });

  double get unitPrice => qty == 0 ? price : price / qty;

  factory ManualPriceDto.fromJson(Map<String, dynamic> aJson) => ManualPriceDto(
        id: aJson['id'] as String,
        placeId: aJson['place_id'] as String?,
        placeAddrId: aJson['place_addr_id'] as String?,
        storeName: aJson['store_name'] as String?,
        branch: aJson['branch'] as String?,
        currCode: aJson['curr_code'] as String? ?? '',
        qty: parseDecimal(aJson['qty']),
        price: parseDecimal(aJson['price']),
        seenTs: parseTs(aJson['seen_ts']),
        note: aJson['note'] as String?,
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
  final bool isAutoTransfer;
  final String? peerAccountName;
  final double? peerAmount;
  final String? peerCurrCode;
  final String? similarKey;
  final String? placeId;
  final String? placeName;
  final String? placeAddrId;
  final String? branch;
  final bool isMerchantLinked;
  final String? accountOwnerName;
  final String? balanceDocId;

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
    this.isAutoTransfer = false,
    this.peerAccountName,
    this.peerAmount,
    this.peerCurrCode,
    this.similarKey,
    this.placeId,
    this.placeName,
    this.placeAddrId,
    this.branch,
    this.isMerchantLinked = false,
    this.accountOwnerName,
    this.balanceDocId,
  });

  bool get isTransfer => transferId != null;
  bool get isManual => source == 'manual';
  bool get isReceiptCash => source == 'receipt_cash';
  bool get isOutflow => amount < 0;

  String get title => placeName ?? merchantName ?? counterparty ?? description ?? note ?? accountName;

  String? get placeLabel => placeName == null ? null : [placeName!, if (branch != null) branch!].join(' · ');

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
        isAutoTransfer: aJson['is_auto_transfer'] as bool? ?? false,
        peerAccountName: aJson['peer_account_name'] as String?,
        peerAmount: parseDecimalOrNull(aJson['peer_amount']),
        peerCurrCode: aJson['peer_curr_code'] as String?,
        similarKey: aJson['similar_key'] as String?,
        placeId: aJson['place_id'] as String?,
        placeName: aJson['place_name'] as String?,
        placeAddrId: aJson['place_addr_id'] as String?,
        branch: aJson['branch'] as String?,
        isMerchantLinked: aJson['is_merchant_linked'] as bool? ?? false,
        accountOwnerName: aJson['account_owner_name'] as String?,
        balanceDocId: aJson['balance_doc_id'] as String?,
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

class NewItemDraft
{
  final String name;
  final ItemKind kind;
  final ItemUnit unit;
  final String? barcode;

  const NewItemDraft({required this.name, required this.kind, required this.unit, this.barcode});

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind.name,
        'unit': unit.wire,
        if (barcode != null) 'barcode': barcode,
      };
}

class NewPlaceDraft
{
  final String? placeId;
  final String name;
  final String? countryCode;
  final String? city;
  final String? street;
  final String? houseNum;
  final String? zip;

  const NewPlaceDraft({
    this.placeId,
    required this.name,
    this.countryCode,
    this.city,
    this.street,
    this.houseNum,
    this.zip,
  });

  bool get isBranch => placeId != null;

  String get address => [
        city,
        [street, houseNum].whereType<String>().join(' '),
      ].whereType<String>().where((aPart) => aPart.trim().isNotEmpty).join(', ');

  factory NewPlaceDraft.fromJson(Map<String, dynamic> aJson) => NewPlaceDraft(
        placeId: aJson['place_id'] as String?,
        name: aJson['name'] as String? ?? '',
        countryCode: aJson['country_code'] as String?,
        city: aJson['city'] as String?,
        street: aJson['street'] as String?,
        houseNum: aJson['house_num'] as String?,
        zip: aJson['zip'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'place_id': placeId,
        'name': name,
        'country_code': countryCode,
        'city': city,
        'street': street,
        'house_num': houseNum,
        'zip': zip,
      };
}

enum LineMatch
{
  barcode,
  alias,
  name,
  similar,
  isNew;

  static LineMatch parse(Object? aValue) => switch (aValue)
  {
    'barcode' => LineMatch.barcode,
    'alias' => LineMatch.alias,
    'name' => LineMatch.name,
    'similar' => LineMatch.similar,
    _ => LineMatch.isNew,
  };
}

class RecognizedLine
{
  final String text;
  final String name;
  final ItemKind kind;
  final ItemUnit unit;
  final double qty;
  final double? unitPrice;
  final double amount;
  final String? barcode;
  final String? itemId;
  final String? itemName;
  final LineMatch match;

  const RecognizedLine({
    required this.text,
    required this.name,
    required this.kind,
    required this.unit,
    required this.qty,
    this.unitPrice,
    required this.amount,
    this.barcode,
    this.itemId,
    this.itemName,
    required this.match,
  });

  factory RecognizedLine.fromJson(Map<String, dynamic> aJson) => RecognizedLine(
        text: aJson['text'] as String? ?? '',
        name: aJson['name'] as String? ?? '',
        kind: ItemKind.parse(aJson['kind']),
        unit: ItemUnit.parse(aJson['unit']),
        qty: parseDecimal(aJson['qty']),
        unitPrice: parseDecimalOrNull(aJson['unit_price']),
        amount: parseDecimal(aJson['amount']),
        barcode: aJson['barcode'] as String?,
        itemId: aJson['item_id'] as String?,
        itemName: aJson['item_name'] as String?,
        match: LineMatch.parse(aJson['match_kind']),
      );
}

class RecognizedReceipt
{
  final DateTime? receiptTs;
  final String? currId;
  final String? currCode;
  final double? total;
  final double linesTotal;
  final double discount;
  final String? storeName;
  final String? placeId;
  final String? placeName;
  final String? placeAddrId;
  final NewPlaceDraft? newPlace;
  final List<RecognizedLine> lines;

  const RecognizedReceipt({
    this.receiptTs,
    this.currId,
    this.currCode,
    this.total,
    required this.linesTotal,
    this.discount = 0,
    this.storeName,
    this.placeId,
    this.placeName,
    this.placeAddrId,
    this.newPlace,
    required this.lines,
  });

  double get payable => linesTotal - discount;

  bool get isTotalMismatch => total != null && (total! - payable).abs() > 0.009;

  factory RecognizedReceipt.fromJson(Map<String, dynamic> aJson) => RecognizedReceipt(
        receiptTs: aJson['receipt_ts'] == null ? null : parseTs(aJson['receipt_ts']),
        currId: aJson['curr_id'] as String?,
        currCode: aJson['curr_code'] as String?,
        total: parseDecimalOrNull(aJson['total']),
        linesTotal: parseDecimal(aJson['lines_total']),
        discount: parseDecimal(aJson['discount']),
        storeName: aJson['store_name'] as String?,
        placeId: aJson['place_id'] as String?,
        placeName: aJson['place_name'] as String?,
        placeAddrId: aJson['place_addr_id'] as String?,
        newPlace: aJson['new_place'] == null ? null : NewPlaceDraft.fromJson(aJson['new_place'] as Map<String, dynamic>),
        lines: (aJson['lines'] as List? ?? const [])
            .map((aItem) => RecognizedLine.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class ReceiptDto
{
  final String id;
  final DateTime receiptTs;
  final String? merchantId;
  final String? merchantName;
  final String? placeId;
  final String? placeName;
  final String? placeAddrId;
  final String? branch;
  final String currId;
  final String currCode;
  final String? cashAccountId;
  final String? note;
  final List<ReceiptItem> items;
  final List<TxDto> txs;
  final double itemsTotal;
  final double discount;
  final double paidTotal;
  final double restAmount;
  final double cashAmount;
  final bool isEditable;
  final String? ownerName;

  const ReceiptDto({
    required this.id,
    required this.receiptTs,
    this.merchantId,
    this.merchantName,
    this.placeId,
    this.placeName,
    this.placeAddrId,
    this.branch,
    required this.currId,
    required this.currCode,
    this.cashAccountId,
    this.note,
    required this.items,
    required this.txs,
    required this.itemsTotal,
    this.discount = 0,
    required this.paidTotal,
    required this.restAmount,
    required this.cashAmount,
    this.isEditable = true,
    this.ownerName,
  });

  factory ReceiptDto.fromJson(Map<String, dynamic> aJson) => ReceiptDto(
        id: aJson['id'] as String,
        receiptTs: parseTs(aJson['receipt_ts']),
        merchantId: aJson['merchant_id'] as String?,
        merchantName: aJson['merchant_name'] as String?,
        placeId: aJson['place_id'] as String?,
        placeName: aJson['place_name'] as String?,
        placeAddrId: aJson['place_addr_id'] as String?,
        branch: aJson['branch'] as String?,
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
        discount: parseDecimal(aJson['discount']),
        paidTotal: parseDecimal(aJson['paid_total']),
        restAmount: parseDecimal(aJson['rest_amount']),
        cashAmount: parseDecimal(aJson['cash_amount']),
        isEditable: aJson['is_editable'] as bool? ?? true,
        ownerName: aJson['owner_name'] as String?,
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
  final double discount;
  final int itemCount;
  final int txCount;
  final String? ownerName;

  const ReceiptListItem({
    required this.id,
    required this.receiptTs,
    this.merchantName,
    this.placeName,
    required this.currCode,
    required this.itemsTotal,
    this.discount = 0,
    required this.itemCount,
    required this.txCount,
    this.ownerName,
  });

  factory ReceiptListItem.fromJson(Map<String, dynamic> aJson) => ReceiptListItem(
        id: aJson['id'] as String,
        receiptTs: parseTs(aJson['receipt_ts']),
        merchantName: aJson['merchant_name'] as String?,
        placeName: aJson['place_name'] as String?,
        currCode: aJson['curr_code'] as String? ?? '',
        itemsTotal: parseDecimal(aJson['items_total']),
        discount: parseDecimal(aJson['discount']),
        itemCount: (aJson['item_count'] as num?)?.toInt() ?? 0,
        txCount: (aJson['tx_count'] as num?)?.toInt() ?? 0,
        ownerName: aJson['owner_name'] as String?,
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

class CashflowData
{
  final List<CashflowSeries> series;
  final List<String> missingRates;

  const CashflowData({required this.series, required this.missingRates});

  factory CashflowData.fromJson(Map<String, dynamic> aJson) => CashflowData(
        series: (aJson['series'] as List? ?? const [])
            .map((aItem) => CashflowSeries.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        missingRates: (aJson['missing_rates'] as List? ?? const []).cast<String>(),
      );
}

enum FlowMode { net, turnover }

class CategoryAmount
{
  final TxCategory? category;
  final double income;
  final double expense;
  final int txCount;

  const CategoryAmount({this.category, required this.income, required this.expense, required this.txCount});

  factory CategoryAmount.fromJson(Map<String, dynamic> aJson) => CategoryAmount(
        category: TxCategory.parse(aJson['category']),
        income: parseDecimal(aJson['income']),
        expense: parseDecimal(aJson['expense']),
        txCount: (aJson['tx_count'] as num?)?.toInt() ?? 0,
      );
}

class CategorySeries
{
  final String currCode;
  final double incomeTotal;
  final double expenseTotal;
  final List<CategoryAmount> items;

  const CategorySeries({
    required this.currCode,
    required this.incomeTotal,
    required this.expenseTotal,
    required this.items,
  });

  factory CategorySeries.fromJson(Map<String, dynamic> aJson) => CategorySeries(
        currCode: aJson['curr_code'] as String? ?? '',
        incomeTotal: parseDecimal(aJson['income_total']),
        expenseTotal: parseDecimal(aJson['expense_total']),
        items: (aJson['items'] as List? ?? const [])
            .map((aItem) => CategoryAmount.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class CategoryStats
{
  final List<CategorySeries> series;
  final List<String> missingRates;

  const CategoryStats({required this.series, required this.missingRates});

  factory CategoryStats.fromJson(Map<String, dynamic> aJson) => CategoryStats(
        series: (aJson['series'] as List? ?? const [])
            .map((aItem) => CategorySeries.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        missingRates: (aJson['missing_rates'] as List? ?? const []).cast<String>(),
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

class BalanceWriteOff
{
  final String id;
  final DateTime txTs;
  final double amount;
  final TxCategory? category;
  final String? note;

  const BalanceWriteOff({required this.id, required this.txTs, required this.amount, this.category, this.note});

  factory BalanceWriteOff.fromJson(Map<String, dynamic> aJson) => BalanceWriteOff(
        id: aJson['id'] as String,
        txTs: parseTs(aJson['tx_ts']),
        amount: parseDecimal(aJson['amount']),
        category: TxCategory.parse(aJson['category']),
        note: aJson['note'] as String?,
      );
}

class BalanceDoc
{
  static const double _epsilon = 0.004;

  final String id;
  final DateTime balanceTs;
  final double amount;
  final String? note;
  final DateTime? prevTs;
  final double? expected;
  final double? delta;
  final List<BalanceWriteOff> writeOffs;

  const BalanceDoc({
    required this.id,
    required this.balanceTs,
    required this.amount,
    this.note,
    this.prevTs,
    this.expected,
    this.delta,
    this.writeOffs = const [],
  });

  bool get isInitial => prevTs == null;

  bool get hasDelta => (delta ?? 0).abs() > _epsilon;

  factory BalanceDoc.fromJson(Map<String, dynamic> aJson) => BalanceDoc(
        id: aJson['id'] as String,
        balanceTs: parseTs(aJson['balance_ts']),
        amount: parseDecimal(aJson['amount']),
        note: aJson['note'] as String?,
        prevTs: aJson['prev_ts'] == null ? null : parseTs(aJson['prev_ts']),
        expected: parseDecimalOrNull(aJson['expected']),
        delta: parseDecimalOrNull(aJson['delta']),
        writeOffs: ((aJson['write_offs'] as List<dynamic>?) ?? const [])
            .map((aItem) => BalanceWriteOff.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class ReceiptPrefill
{
  final String cashAccountId;
  final String currId;
  final DateTime ts;

  const ReceiptPrefill({required this.cashAccountId, required this.currId, required this.ts});
}
