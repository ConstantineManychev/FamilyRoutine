import 'finance_models.dart';

class ProductCat
{
  final String id;
  final String? parentId;
  final String? code;
  final String name;
  final int depth;
  final int itemCount;
  final ItemOwnerKind ownerKind;
  final bool isEditable;
  final bool isInUse;

  const ProductCat({
    required this.id,
    this.parentId,
    this.code,
    required this.name,
    this.depth = 1,
    this.itemCount = 0,
    this.ownerKind = ItemOwnerKind.user,
    this.isEditable = false,
    this.isInUse = false,
  });

  factory ProductCat.fromJson(Map<String, dynamic> aJson) => ProductCat(
        id: aJson['id'] as String,
        parentId: aJson['parent_id'] as String?,
        code: aJson['code'] as String?,
        name: aJson['name'] as String? ?? '',
        depth: (aJson['depth'] as num?)?.toInt() ?? 1,
        itemCount: (aJson['item_count'] as num?)?.toInt() ?? 0,
        ownerKind: ItemOwnerKind.parse(aJson['owner_kind']),
        isEditable: aJson['is_editable'] as bool? ?? false,
        isInUse: aJson['is_in_use'] as bool? ?? false,
      );

  bool get canChange => isEditable && (!isInUse || ownerKind != ItemOwnerKind.me);
}

class ProductCatTree
{
  final int maxDepth;
  final bool isAdmin;
  final List<ProductCat> nodes;
  final Map<String, ProductCat> _byId;
  final Map<String?, List<ProductCat>> _children;

  ProductCatTree({required this.maxDepth, this.isAdmin = false, required this.nodes})
      : _byId = {for (final node in nodes) node.id: node},
        _children = _group(nodes);

  static Map<String?, List<ProductCat>> _group(List<ProductCat> aNodes)
  {
    final children = <String?, List<ProductCat>>{};
    for (final node in aNodes)
    {
      children.putIfAbsent(node.parentId, () => []).add(node);
    }
    return children;
  }

  factory ProductCatTree.fromJson(Map<String, dynamic> aJson) => ProductCatTree(
        maxDepth: (aJson['max_depth'] as num?)?.toInt() ?? 3,
        isAdmin: aJson['is_admin'] as bool? ?? false,
        nodes: (aJson['nodes'] as List? ?? const [])
            .map((aItem) => ProductCat.fromJson(aItem as Map<String, dynamic>))
            .toList(),
      );

  ProductCat? operator [](String? aId) => aId == null ? null : _byId[aId];

  List<ProductCat> children(String? aParentId) => _children[aParentId] ?? const [];

  List<ProductCat> roots() => children(null);

  List<ProductCat> path(String? aId)
  {
    final path = <ProductCat>[];
    final seen = <String>{};
    var current = this[aId];
    while (current != null && seen.add(current.id))
    {
      path.insert(0, current);
      current = this[current.parentId];
    }
    return path;
  }

  List<ProductCat> subtree(String aId)
  {
    final result = <ProductCat>[];
    final start = this[aId];
    final queue = <ProductCat>[if (start != null) start];
    final seen = <String>{};
    while (queue.isNotEmpty)
    {
      final node = queue.removeAt(0);
      if (!seen.add(node.id))
      {
        continue;
      }
      result.add(node);
      queue.addAll(children(node.id));
    }
    return result;
  }

  int branchItemCount(String aId) => subtree(aId).fold(0, (aSum, aNode) => aSum + aNode.itemCount);

  bool canAddChild(String? aParentId) => aParentId == null || (this[aParentId]?.depth ?? maxDepth) < maxDepth;

  bool isWithin(String aId, String aRootId) => path(aId).any((aNode) => aNode.id == aRootId);
}

class CatPriceRow
{
  final String itemId;
  final String itemName;
  final String? catId;
  final NetMeasure measure;
  final String currCode;
  final double best100;
  final String? bestStore;
  final String? bestBranch;
  final DateTime bestTs;
  final double last100;
  final String? lastStore;
  final DateTime lastTs;
  final int count;

  const CatPriceRow({
    required this.itemId,
    required this.itemName,
    this.catId,
    required this.measure,
    required this.currCode,
    required this.best100,
    this.bestStore,
    this.bestBranch,
    required this.bestTs,
    required this.last100,
    this.lastStore,
    required this.lastTs,
    this.count = 1,
  });

  factory CatPriceRow.fromJson(Map<String, dynamic> aJson) => CatPriceRow(
        itemId: aJson['item_id'] as String,
        itemName: aJson['item_name'] as String? ?? '',
        catId: aJson['cat_id'] as String?,
        measure: NetMeasure.parse(aJson['measure']) ?? NetMeasure.g,
        currCode: aJson['curr_code'] as String? ?? '',
        best100: parseDecimal(aJson['best_100']),
        bestStore: aJson['best_store'] as String?,
        bestBranch: aJson['best_branch'] as String?,
        bestTs: parseTs(aJson['best_ts']),
        last100: parseDecimal(aJson['last_100']),
        lastStore: aJson['last_store'] as String?,
        lastTs: parseTs(aJson['last_ts']),
        count: (aJson['count'] as num?)?.toInt() ?? 1,
      );
}

class CatPrices
{
  final List<CatPriceRow> rows;
  final List<({String id, String name})> unmeasured;
  final bool isMissingRates;

  const CatPrices({this.rows = const [], this.unmeasured = const [], this.isMissingRates = false});

  factory CatPrices.fromJson(Map<String, dynamic> aJson) => CatPrices(
        rows: (aJson['rows'] as List? ?? const [])
            .map((aItem) => CatPriceRow.fromJson(aItem as Map<String, dynamic>))
            .toList(),
        unmeasured: (aJson['unmeasured'] as List? ?? const [])
            .map((aItem) => aItem as Map<String, dynamic>)
            .map((aItem) => (id: aItem['id'] as String, name: aItem['name'] as String? ?? ''))
            .toList(),
        isMissingRates: aJson['missing_rates'] as bool? ?? false,
      );
}
