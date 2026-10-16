import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';

const int maxCatNameLen = 100;
const String catPathSeparator = ' › ';
const double _indentStep = 20;

final FutureProvider<ProductCatTree> productCatsProv = FutureProvider<ProductCatTree>((aRef) => aRef.read(apiProv).getProductCats());

String catLabel(ProductCat aCat)
{
  final code = aCat.code;
  if (code == null)
  {
    return aCat.name;
  }
  final key = 'product_cats.$code';
  final text = key.tr();
  return text == key ? aCat.name : text;
}

String catPathLabel(ProductCatTree aTree, String? aId) => aTree.path(aId).map(catLabel).join(catPathSeparator);

List<ProductCat> sortedChildren(ProductCatTree aTree, String? aParentId) =>
    [...aTree.children(aParentId)]..sort((aLeft, aRight) => catLabel(aLeft).toLowerCase().compareTo(catLabel(aRight).toLowerCase()));

String catLevelLabel(int aDepth) => aDepth <= 3 ? 'cats.level_$aDepth'.tr() : 'cats.level_n'.tr(args: ['$aDepth']);

Future<String?> askCatName(BuildContext aContext, {required String aTitle, String aInitial = ''}) async
{
  final ctrl = TextEditingController(text: aInitial);
  final name = await showDialog<String>(
    context: aContext,
    builder: (aDialogContext) => AlertDialog(
      title: Text(aTitle),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        inputFormatters: [LengthLimitingTextInputFormatter(maxCatNameLen)],
        decoration: InputDecoration(labelText: 'cats.name'.tr(), border: const OutlineInputBorder()),
        onSubmitted: (aValue) => Navigator.of(aDialogContext).pop(aValue.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aDialogContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: () => Navigator.of(aDialogContext).pop(ctrl.text.trim()), child: Text('common.save'.tr())),
      ],
    ),
  );
  ctrl.dispose();
  return name == null || name.isEmpty ? null : name;
}

Future<ProductCat?> createProductCat(BuildContext aContext, WidgetRef aRef, ProductCatTree aTree, String? aParentId) async
{
  final parent = aTree[aParentId];
  final title = parent == null ? 'cats.new_root'.tr() : 'cats.new_child'.tr(args: [catLabel(parent)]);
  final name = await askCatName(aContext, aTitle: title);
  if (name == null || !aContext.mounted)
  {
    return null;
  }
  final duplicate = aTree.children(aParentId).where((aCat) => catLabel(aCat).toLowerCase() == name.toLowerCase()).firstOrNull;
  if (duplicate != null)
  {
    showInfoSnack(aContext, 'cats.exists'.tr(args: [catLabel(duplicate)]));
    return duplicate;
  }
  try
  {
    final created = await aRef.read(apiProv).saveProductCat(null, name, aParentId);
    aRef.invalidate(productCatsProv);
    return created;
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
    return null;
  }
}

class CatPickResult
{
  final String? catId;

  const CatPickResult(this.catId);
}

Future<CatPickResult?> pickProductCat(BuildContext aContext, {String? aInitialId, String? aExcludeId, bool aIsRootAllowed = false})
{
  return Navigator.of(aContext).push<CatPickResult>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _CatPickerPage(initialId: aInitialId, excludeId: aExcludeId, isRootAllowed: aIsRootAllowed),
  ));
}

class _CatPickerPage extends ConsumerStatefulWidget
{
  final String? initialId;
  final String? excludeId;
  final bool isRootAllowed;

  const _CatPickerPage({this.initialId, this.excludeId, this.isRootAllowed = false});

  @override
  ConsumerState<_CatPickerPage> createState() => _CatPickerPageState();
}

class _CatPickerPageState extends ConsumerState<_CatPickerPage>
{
  final Set<String> _expanded = {};
  String _query = '';
  bool _isInitialized = false;

  void _expandTo(ProductCatTree aTree)
  {
    if (_isInitialized)
    {
      return;
    }
    _isInitialized = true;
    for (final node in aTree.path(widget.initialId))
    {
      _expanded.add(node.id);
    }
  }

  bool _isExcluded(ProductCatTree aTree, ProductCat aCat)
  {
    final excluded = widget.excludeId;
    return excluded != null && aTree.isWithin(aCat.id, excluded);
  }

  Future<void> _create(ProductCatTree aTree, String? aParentId) async
  {
    final created = await createProductCat(context, ref, aTree, aParentId);
    if (created != null && mounted)
    {
      Navigator.of(context).pop(CatPickResult(created.id));
    }
  }

  Widget _tile(BuildContext aContext, ProductCatTree aTree, ProductCat aCat, int aIndent)
  {
    final palette = aContext.palette;
    final children = aTree.children(aCat.id);
    final isExpanded = _expanded.contains(aCat.id);
    final isSelected = aCat.id == widget.initialId;
    final isExcluded = _isExcluded(aTree, aCat);

    return ListTile(
      key: ValueKey('cat.pick.${aCat.id}'),
      contentPadding: EdgeInsets.only(left: 8 + aIndent * _indentStep, right: 8),
      enabled: !isExcluded,
      selected: isSelected,
      onTap: () => Navigator.of(aContext).pop(CatPickResult(aCat.id)),
      leading: children.isEmpty
          ? const SizedBox(width: 40)
          : IconButton(
              tooltip: isExpanded ? 'cats.collapse'.tr() : 'cats.expand'.tr(),
              onPressed: () => setState(() => isExpanded ? _expanded.remove(aCat.id) : _expanded.add(aCat.id)),
              icon: Icon(isExpanded ? AppIcons.chevronDown : AppIcons.chevronRight, size: 18),
            ),
      title: Text(catLabel(aCat)),
      subtitle: Text(catLevelLabel(aCat.depth), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
      trailing: aTree.canAddChild(aCat.id) && !isExcluded
          ? IconButton(
              tooltip: 'cats.add_child'.tr(),
              onPressed: () => _create(aTree, aCat.id),
              icon: Icon(AppIcons.plus, size: 18, color: aContext.colors.primary),
            )
          : null,
    );
  }

  List<Widget> _branch(BuildContext aContext, ProductCatTree aTree, String? aParentId, int aIndent)
  {
    final tiles = <Widget>[];
    for (final cat in sortedChildren(aTree, aParentId))
    {
      tiles.add(_tile(aContext, aTree, cat, aIndent));
      if (_expanded.contains(cat.id))
      {
        tiles.addAll(_branch(aContext, aTree, cat.id, aIndent + 1));
      }
    }
    return tiles;
  }

  List<Widget> _matches(BuildContext aContext, ProductCatTree aTree)
  {
    final query = _query.toLowerCase();
    final found = aTree.nodes.where((aCat) => catLabel(aCat).toLowerCase().contains(query) && !_isExcluded(aTree, aCat)).toList()
      ..sort((aLeft, aRight) => catPathLabel(aTree, aLeft.id).compareTo(catPathLabel(aTree, aRight.id)));
    if (found.isEmpty)
    {
      return [BlockEmpty('cats.nothing_found'.tr())];
    }
    return [
      for (final cat in found)
        ListTile(
          onTap: () => Navigator.of(aContext).pop(CatPickResult(cat.id)),
          title: Text(catLabel(cat)),
          subtitle: Text(catPathLabel(aTree, cat.id), style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted)),
        ),
    ];
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final treeAsync = ref.watch(productCatsProv);

    return SubPage(
      title: 'cats.pick'.tr(),
      child: treeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(productCatsProv)),
        data: (aTree)
        {
          _expandTo(aTree);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  inputFormatters: [LengthLimitingTextInputFormatter(maxCatNameLen)],
                  onChanged: (aValue) => setState(() => _query = aValue.trim()),
                  decoration: InputDecoration(
                    hintText: 'cats.search'.tr(),
                    prefixIcon: const Icon(AppIcons.search, size: 18),
                    isDense: true,
                    filled: true,
                    fillColor: aContext.palette.surfaceMuted,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (widget.isRootAllowed)
                      ListTile(
                        onTap: () => Navigator.of(aContext).pop(const CatPickResult(null)),
                        leading: const Icon(AppIcons.home),
                        title: Text('cats.root_level'.tr()),
                      )
                    else if (widget.initialId != null)
                      ListTile(
                        onTap: () => Navigator.of(aContext).pop(const CatPickResult(null)),
                        leading: const Icon(AppIcons.x),
                        title: Text('cats.none'.tr()),
                      ),
                    if (_query.isEmpty) ..._branch(aContext, aTree, null, 0) else ..._matches(aContext, aTree),
                    ListTile(
                      onTap: () => _create(aTree, null),
                      leading: Icon(AppIcons.plusCircle, color: aContext.colors.primary),
                      title: Text('cats.new_root'.tr()),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
