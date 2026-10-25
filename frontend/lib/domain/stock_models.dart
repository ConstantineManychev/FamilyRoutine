import 'finance_models.dart';
import 'nutrition_models.dart';
import 'planner_models.dart';

T _parseEnum<T extends Enum>(List<T> aValues, Object? aValue, T aFallback) =>
    aValues.where((aItem) => aItem.name == aValue).firstOrNull ?? aFallback;

enum StockMeasure
{
  g,
  ml,
  pcs;

  static StockMeasure parse(Object? aValue) => _parseEnum(values, aValue, StockMeasure.g);

  bool get isMass => this != StockMeasure.pcs;
}

enum StockKind
{
  item,
  dish;

  static StockKind parse(Object? aValue) => _parseEnum(values, aValue, StockKind.item);
}

enum StockSource
{
  receipt,
  manual,
  cooked;

  static StockSource parse(Object? aValue) => _parseEnum(values, aValue, StockSource.manual);
}

enum StockMoveKind
{
  eaten,
  cooked,
  waste,
  used;

  static StockMoveKind parse(Object? aValue) => _parseEnum(values, aValue, StockMoveKind.eaten);
}

enum WasteReason
{
  spoiled,
  leftovers,
  other,
  expired;

  static WasteReason? parseOrNull(Object? aValue) => values.where((aItem) => aItem.name == aValue).firstOrNull;
}

class StockStoreRef
{
  final String? familyId;
  final String? familyName;

  const StockStoreRef({this.familyId, this.familyName});

  static const StockStoreRef personal = StockStoreRef();

  bool get isPersonal => familyId == null;

  bool isSame(StockStoreRef aOther) => aOther.familyId == familyId;

  Map<String, dynamic> get query => isPersonal ? {'is_personal': true} : {'family_id': familyId};
}

class StockStore
{
  final StockStoreRef ref;
  final bool isActive;
  final int lotCount;

  const StockStore({required this.ref, this.isActive = false, this.lotCount = 0});

  factory StockStore.fromJson(Map<String, dynamic> aJson) => StockStore(
        ref: StockStoreRef(familyId: aJson['family_id'] as String?, familyName: aJson['family_name'] as String?),
        isActive: aJson['is_active'] as bool? ?? false,
        lotCount: (aJson['lot_count'] as num?)?.toInt() ?? 0,
      );
}

class StockSettings
{
  final String? activeFamilyId;
  final List<StockStore> stores;

  const StockSettings({this.activeFamilyId, this.stores = const []});

  factory StockSettings.fromJson(Map<String, dynamic> aJson) => StockSettings(
        activeFamilyId: aJson['active_family_id'] as String?,
        stores: (aJson['stores'] as List? ?? const [])
            .map((aItem) => StockStore.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  StockStore get active => stores.where((aStore) => aStore.isActive).firstOrNull ?? stores.firstOrNull ?? const StockStore(ref: StockStoreRef.personal, isActive: true);
}

class StockLot
{
  final String id;
  final StockKind kind;
  final String? itemId;
  final String? dishId;
  final String? batchId;
  final String title;
  final StockMeasure measure;
  final double qty;
  final double leftQty;
  final double? cost;
  final double? leftCost;
  final String? currCode;
  final StockSource source;
  final String? receiptId;
  final DateTime acquiredTs;
  final bool isTouched;
  final double? pieceG;
  final double? packSize;
  final Macros? per100;
  final DateTime? expiresOn;
  final bool isExpired;

  const StockLot({
    required this.id,
    this.kind = StockKind.item,
    this.itemId,
    this.dishId,
    this.batchId,
    required this.title,
    this.measure = StockMeasure.g,
    required this.qty,
    required this.leftQty,
    this.cost,
    this.leftCost,
    this.currCode,
    this.source = StockSource.manual,
    this.receiptId,
    required this.acquiredTs,
    this.isTouched = false,
    this.pieceG,
    this.packSize,
    this.per100,
    this.expiresOn,
    this.isExpired = false,
  });

  bool get isPackKnown => measure.isMass && (packSize ?? 0) > 0;

  bool get isUnmeasured => kind == StockKind.item && measure == StockMeasure.pcs;

  double? get leftPieces => isPackKnown ? leftQty / packSize! : null;

  double? get qtyPieces => isPackKnown ? qty / packSize! : null;

  bool get isRemovable => !isTouched && source != StockSource.receipt;

  int? daysLeft(DateTime aToday)
  {
    final expiresOn = this.expiresOn;
    if (expiresOn == null)
    {
      return null;
    }
    final today = DateTime(aToday.year, aToday.month, aToday.day);
    return DateTime.utc(expiresOn.year, expiresOn.month, expiresOn.day)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;
  }

  String get groupKey => kind == StockKind.dish ? 'dish:$id' : 'item:${itemId ?? title}';

  factory StockLot.fromJson(Map<String, dynamic> aJson) => StockLot(
        id: aJson['id'] as String,
        kind: StockKind.parse(aJson['kind']),
        itemId: aJson['item_id'] as String?,
        dishId: aJson['dish_id'] as String?,
        batchId: aJson['batch_id'] as String?,
        title: aJson['title'] as String? ?? '',
        measure: StockMeasure.parse(aJson['measure']),
        qty: parseDecimal(aJson['qty']),
        leftQty: parseDecimal(aJson['left_qty']),
        cost: parseDecimalOrNull(aJson['cost']),
        leftCost: parseDecimalOrNull(aJson['left_cost']),
        currCode: aJson['curr_code'] as String?,
        source: StockSource.parse(aJson['source']),
        receiptId: aJson['receipt_id'] as String?,
        acquiredTs: parseTs(aJson['acquired_ts']),
        isTouched: aJson['is_touched'] as bool? ?? false,
        pieceG: parseDecimalOrNull(aJson['piece_g']),
        packSize: parseDecimalOrNull(aJson['pack_size']),
        per100: Macros.fromJsonOrNull(aJson['per_100']),
        expiresOn: aJson['expires_on'] == null ? null : parseDateWire(aJson['expires_on']),
        isExpired: aJson['is_expired'] as bool? ?? false,
      );
}

class StockGroup
{
  final String key;
  final List<StockLot> lots;

  const StockGroup(this.key, this.lots);

  StockLot get first => lots.first;

  String get title => first.title;

  StockKind get kind => first.kind;

  StockMeasure get measure => first.measure;

  double get leftQty => lots.where((aLot) => aLot.measure == measure).fold(0, (aSum, aLot) => aSum + aLot.leftQty);

  String? get itemId => first.itemId;

  double? get packSize => lots.where((aLot) => aLot.measure == measure && aLot.isPackKnown).firstOrNull?.packSize;

  double? get leftPieces
  {
    final measured = lots.where((aLot) => aLot.measure == measure && aLot.isPackKnown).toList();
    if (measured.isEmpty)
    {
      return null;
    }
    return measured.fold<double>(0, (aSum, aLot) => aSum + (aLot.leftPieces ?? 0));
  }

  bool get isUnmeasured => first.isUnmeasured;

  StockLot? get soonest
  {
    StockLot? found;
    for (final lot in lots)
    {
      final expiresOn = lot.expiresOn;
      final current = found?.expiresOn;
      if (expiresOn != null && (current == null || expiresOn.isBefore(current)))
      {
        found = lot;
      }
    }
    return found;
  }
}

class StockData
{
  final StockStoreRef store;
  final bool isActive;
  final List<StockLot> lots;

  const StockData({required this.store, this.isActive = false, this.lots = const []});

  factory StockData.fromJson(Map<String, dynamic> aJson) => StockData(
        store: StockStoreRef(familyId: aJson['family_id'] as String?, familyName: aJson['family_name'] as String?),
        isActive: aJson['is_active'] as bool? ?? false,
        lots: (aJson['lots'] as List? ?? const [])
            .map((aItem) => StockLot.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  List<StockGroup> groupsOf(StockKind aKind)
  {
    final groups = <String, List<StockLot>>{};
    for (final lot in lots.where((aLot) => aLot.kind == aKind))
    {
      groups.putIfAbsent(lot.groupKey, () => []).add(lot);
    }
    return [for (final entry in groups.entries) StockGroup(entry.key, entry.value)];
  }
}

class CookBatchItem
{
  final String? itemId;
  final String itemName;
  final double grams;
  final double shortG;

  const CookBatchItem({this.itemId, required this.itemName, required this.grams, this.shortG = 0});

  factory CookBatchItem.fromJson(Map<String, dynamic> aJson) => CookBatchItem(
        itemId: aJson['item_id'] as String?,
        itemName: aJson['item_name'] as String? ?? '',
        grams: parseDecimal(aJson['grams']),
        shortG: parseDecimal(aJson['short_g']),
      );
}

class CookBatch
{
  final String id;
  final String lotId;
  final String? dishId;
  final String? familyId;
  final String title;
  final DateTime cookedTs;
  final double rawG;
  final double cookedG;
  final double leftG;
  final Macros per100;
  final int missingCount;
  final double? cost;
  final String? currCode;
  final String? note;
  final DateTime? expiresOn;
  final List<CookBatchItem> ingredients;

  const CookBatch({
    required this.id,
    required this.lotId,
    this.dishId,
    this.familyId,
    required this.title,
    required this.cookedTs,
    required this.rawG,
    required this.cookedG,
    required this.leftG,
    this.per100 = Macros.zero,
    this.missingCount = 0,
    this.cost,
    this.currCode,
    this.note,
    this.expiresOn,
    this.ingredients = const [],
  });

  double get shortG => ingredients.fold(0, (aSum, aItem) => aSum + aItem.shortG);

  factory CookBatch.fromJson(Map<String, dynamic> aJson) => CookBatch(
        id: aJson['id'] as String,
        lotId: aJson['lot_id'] as String,
        dishId: aJson['dish_id'] as String?,
        familyId: aJson['family_id'] as String?,
        title: aJson['title'] as String? ?? '',
        cookedTs: parseTs(aJson['cooked_ts']),
        rawG: parseDecimal(aJson['raw_g']),
        cookedG: parseDecimal(aJson['cooked_g']),
        leftG: parseDecimal(aJson['left_g']),
        per100: Macros.fromJson(aJson['per_100']),
        missingCount: (aJson['missing_count'] as num?)?.toInt() ?? 0,
        cost: parseDecimalOrNull(aJson['cost']),
        currCode: aJson['curr_code'] as String?,
        note: aJson['note'] as String?,
        expiresOn: aJson['expires_on'] == null ? null : parseDateWire(aJson['expires_on']),
        ingredients: (aJson['ingredients'] as List? ?? const [])
            .map((aItem) => CookBatchItem.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class StockMove
{
  final String id;
  final StockMoveKind kind;
  final String lotId;
  final String title;
  final StockMeasure measure;
  final double qty;
  final double? cost;
  final String? currCode;
  final WasteReason? reason;
  final String? note;
  final String? actorName;
  final DateTime createdTs;

  const StockMove({
    required this.id,
    required this.kind,
    required this.lotId,
    required this.title,
    this.measure = StockMeasure.g,
    required this.qty,
    this.cost,
    this.currCode,
    this.reason,
    this.note,
    this.actorName,
    required this.createdTs,
  });

  factory StockMove.fromJson(Map<String, dynamic> aJson) => StockMove(
        id: aJson['id'] as String,
        kind: StockMoveKind.parse(aJson['kind']),
        lotId: aJson['lot_id'] as String,
        title: aJson['title'] as String? ?? '',
        measure: StockMeasure.parse(aJson['measure']),
        qty: parseDecimal(aJson['qty']),
        cost: parseDecimalOrNull(aJson['cost']),
        currCode: aJson['curr_code'] as String?,
        reason: WasteReason.parseOrNull(aJson['reason']),
        note: aJson['note'] as String?,
        actorName: aJson['actor_name'] as String?,
        createdTs: parseTs(aJson['created_ts']),
      );
}

class MoneyTotal
{
  final String currCode;
  final double amount;

  const MoneyTotal({required this.currCode, required this.amount});

  factory MoneyTotal.fromJson(Map<String, dynamic> aJson) =>
      MoneyTotal(currCode: aJson['curr_code'] as String? ?? '', amount: parseDecimal(aJson['amount']));
}

class StockMoves
{
  final List<StockMove> moves;
  final double wasteG;
  final double wasteMl;
  final double wastePcs;
  final List<MoneyTotal> wasteCosts;

  const StockMoves({this.moves = const [], this.wasteG = 0, this.wasteMl = 0, this.wastePcs = 0, this.wasteCosts = const []});

  factory StockMoves.fromJson(Map<String, dynamic> aJson) => StockMoves(
        moves: (aJson['moves'] as List? ?? const [])
            .map((aItem) => StockMove.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        wasteG: parseDecimal(aJson['waste_g']),
        wasteMl: parseDecimal(aJson['waste_ml']),
        wastePcs: parseDecimal(aJson['waste_pcs']),
        wasteCosts: (aJson['waste_costs'] as List? ?? const [])
            .map((aItem) => MoneyTotal.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );
}

class CookIngredient
{
  final String itemId;
  final String itemName;
  final double grams;

  const CookIngredient({required this.itemId, required this.itemName, required this.grams});

  CookIngredient withGrams(double aGrams) => CookIngredient(itemId: itemId, itemName: itemName, grams: aGrams);
}

class StockFoods
{
  final Map<String, String?> itemCats;
  final Set<String> dishIds;

  const StockFoods({this.itemCats = const {}, this.dishIds = const {}});

  factory StockFoods.fromJson(Map<String, dynamic> aJson) => StockFoods(
        itemCats: {
          for (final item in (aJson['items'] as List? ?? const []).cast<Map<String, dynamic>>())
            item['item_id'] as String: item['cat_id'] as String?,
        },
        dishIds: {for (final id in aJson['dish_ids'] as List? ?? const []) id as String},
      );

  bool hasItem(String? aId) => aId != null && itemCats.containsKey(aId);

  bool hasDish(String? aId) => aId != null && dishIds.contains(aId);

  bool hasFood(RecentFood aFood) => aFood.dishId != null ? hasDish(aFood.dishId) : hasItem(aFood.itemId);

  Set<String> get catIds => itemCats.values.whereType<String>().toSet();
}
