import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'item_form.dart';
import 'item_prices_section.dart';
import 'items_screen.dart';
import 'scope_widgets.dart';

enum _ItemAction { share, merge }

class ItemDetailScreen extends ConsumerStatefulWidget
{
  final String? itemId;
  final String? initialBarcode;

  const ItemDetailScreen({super.key, this.itemId, this.initialBarcode});

  @override
  ConsumerState<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends ConsumerState<ItemDetailScreen>
{
  final _nameCtrl = TextEditingController();
  final _barcodeCtrl = TextEditingController();
  ItemKind _kind = ItemKind.product;
  ItemUnit _unit = ItemUnit.piece;
  DictItemDto? _item;
  String? _familyId;
  bool _isLoading = false;
  bool _isSaving = false;
  Object? _loadError;

  bool get _isEdit => widget.itemId != null;

  bool get _isEditable => !_isEdit || (_item?.isEditable ?? false);

  @override
  void initState()
  {
    super.initState();
    if (_isEdit)
    {
      _load();
    }
    else
    {
      _barcodeCtrl.text = widget.initialBarcode ?? '';
    }
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    _barcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    setState(()
    {
      _isLoading = true;
      _loadError = null;
    });

    try
    {
      final item = await ref.read(apiProv).getItem(widget.itemId!);
      if (!mounted)
      {
        return;
      }

      setState(() => _apply(item));
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isLoading = false);
      }
    }
  }

  void _apply(DictItemDto aItem)
  {
    _item = aItem;
    _nameCtrl.text = aItem.name;
    _barcodeCtrl.text = aItem.barcode ?? '';
    _kind = aItem.kind;
    _unit = aItem.unit;
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isSaving = true);
    try
    {
      await aAction();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _save() async
  {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty)
    {
      showInfoSnack(context, 'items.err_name'.tr());
      return;
    }
    if (!isBarcodeAcceptable(_barcodeCtrl.text))
    {
      showInfoSnack(context, 'items.barcode_invalid'.tr());
      return;
    }

    await _run(() async
    {
      final saved = await ref.read(apiProv).saveItem(
            widget.itemId,
            DictItemDto.payload(name, _kind, _unit, aBarcode: _barcodeCtrl.text, aFamilyId: _isEdit ? null : _familyId),
          );
      ref.invalidate(itemsProv);
      if (!mounted)
      {
        return;
      }

      showInfoSnack(context, 'common.saved'.tr());
      if (_isEdit)
      {
        setState(() => _apply(saved));
      }
      else
      {
        context.go('/app/items/${saved.id}');
      }
    });
  }

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'items.delete'.tr(),
      aMessage: 'items.delete_confirm'.tr(),
    );

    if (!isConfirmed || !mounted)
    {
      return;
    }

    await _run(() async
    {
      await ref.read(apiProv).deleteItem(widget.itemId!);
      ref.invalidate(itemsProv);
      if (mounted)
      {
        context.go('/app/items');
      }
    });
  }

  Future<void> _share() async
  {
    final fams = ref.read(famsProv).valueOrNull ?? const <FamDto>[];
    final familyId = await showShareToFamilyDialog(context, fams, 'catalog.share_item'.tr());
    if (familyId == null || !mounted)
    {
      return;
    }

    await _run(() async
    {
      final shared = await ref.read(apiProv).shareItem(widget.itemId!, familyId);
      ref.invalidate(itemsProv);
      if (mounted)
      {
        setState(() => _apply(shared));
      }
    });
  }

  Future<void> _merge() async
  {
    final source = _item;
    if (source == null)
    {
      return;
    }

    final target = await showDialog<DictItemDto>(context: context, builder: (_) => _MergeDialog(source: source));
    if (target == null || !mounted)
    {
      return;
    }

    await _run(() async
    {
      final merged = await ref.read(apiProv).mergeItem(source.id, target.id);
      ref.invalidate(itemsProv);
      if (mounted)
      {
        showInfoSnack(context, 'items.merged'.tr(args: [merged.name]));
        context.go('/app/items/${merged.id}');
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    if (_isLoading && _item == null)
    {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError != null)
    {
      return ErrorRetry(error: _loadError!, onRetry: _load);
    }

    final item = _item;
    final fams = ref.watch(famsProv).valueOrNull ?? const <FamDto>[];
    final canShare = item != null && item.isPersonal && fams.isNotEmpty;
    final canMerge = item != null && item.isEditable;

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'items.item'.tr() : 'items.new'.tr(),
          actions: [
            if (canShare || canMerge)
              PopupMenuButton<_ItemAction>(
                tooltip: 'common.actions'.tr(),
                icon: const Icon(AppIcons.moreVertical),
                enabled: !_isSaving,
                onSelected: (aAction) => aAction == _ItemAction.share ? _share() : _merge(),
                itemBuilder: (_) => [
                  if (canShare)
                    PopupMenuItem(
                      value: _ItemAction.share,
                      child: ListTile(leading: const Icon(AppIcons.users, size: 18), title: Text('catalog.share_item'.tr())),
                    ),
                  if (canMerge)
                    PopupMenuItem(
                      value: _ItemAction.merge,
                      child: ListTile(leading: const Icon(AppIcons.merge, size: 18), title: Text('items.merge'.tr())),
                    ),
                ],
              ),
            if (_isEdit && _isEditable)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(AppIcons.trash2, size: 18),
                label: Text('common.delete'.tr()),
              ),
            if (_isEditable)
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(AppIcons.save, size: 18),
                label: Text('common.save'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (item?.familyName != null) ...[
          Align(alignment: Alignment.centerLeft, child: FamilyBadge(name: item!.familyName!)),
          const SizedBox(height: 12),
        ],
        if (!_isEditable) ...[
          Row(
            children: [
              const Icon(AppIcons.lock, size: 18, color: inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item?.familyId != null ? 'items.family_readonly_hint'.tr() : 'items.system_hint'.tr(),
                  style: const TextStyle(color: inkSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ItemFormFields(
            nameCtrl: _nameCtrl,
            barcodeCtrl: _barcodeCtrl,
            kind: _kind,
            unit: _unit,
            isEnabled: _isEditable,
            scopeFams: _isEdit ? null : fams,
            scopeFamilyId: _familyId,
            onScopeChanged: _isEdit ? null : (aValue) => setState(() => _familyId = aValue),
            onScanBarcode: () => scanIntoBarcodeField(context, ref, _barcodeCtrl, aCurrentItemId: widget.itemId),
            onKindChanged: (aKind) => setState(() => _kind = aKind),
            onUnitChanged: (aUnit) => setState(() => _unit = aUnit),
          ),
        ),
        if (item != null) ...[
          const SizedBox(height: 32),
          ItemPricesSection(key: ValueKey('${item.id}:${item.unit.wire}:${item.barcode}'), item: item),
        ],
      ],
    );
  }
}

class _MergeDialog extends ConsumerStatefulWidget
{
  final DictItemDto source;

  const _MergeDialog({required this.source});

  @override
  ConsumerState<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends ConsumerState<_MergeDialog>
{
  static const Duration _searchDelay = Duration(milliseconds: 300);

  Timer? _searchTimer;
  List<DictItemDto> _options = const [];
  DictItemDto? _target;

  @override
  void initState()
  {
    super.initState();
    _search('');
  }

  @override
  void dispose()
  {
    _searchTimer?.cancel();
    super.dispose();
  }

  bool _isCompatible(DictItemDto aItem)
  {
    final source = widget.source;
    final isSameScope = source.familyId == null || aItem.familyId == source.familyId;
    return aItem.id != source.id && aItem.unit == source.unit && isSameScope;
  }

  void _onChanged(String aValue)
  {
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchDelay, () => _search(aValue));
  }

  Future<void> _search(String aQuery) async
  {
    try
    {
      final items = await ref.read(apiProv).getItems(aQuery: aQuery, aLimit: 30);
      if (mounted)
      {
        setState(() => _options = items.where(_isCompatible).toList());
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final target = _target;

    return AlertDialog(
      title: Text('items.merge'.tr()),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('items.merge_hint'.tr(args: [widget.source.name]), style: const TextStyle(color: inkSecondary)),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              onChanged: _onChanged,
              decoration: InputDecoration(
                hintText: 'items.search'.tr(),
                prefixIcon: const Icon(AppIcons.search, size: 18),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _options.isEmpty
                  ? Center(child: Text('common.no_data'.tr(), style: const TextStyle(color: inkMuted)))
                  : RadioGroup<String>(
                      groupValue: target?.id,
                      onChanged: (aId) => setState(() => _target = _options.where((aItem) => aItem.id == aId).firstOrNull),
                      child: ListView(
                        children: _options
                            .map((aItem) => RadioListTile<String>(
                                  value: aItem.id,
                                  title: Text(aItem.name),
                                  subtitle: Text([
                                    itemUnitShort(aItem.unit),
                                    if (aItem.barcode != null) aItem.barcode!,
                                    if (aItem.familyName != null) aItem.familyName!,
                                  ].join(' · ')),
                                ))
                            .toList(),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: target == null ? null : () => Navigator.of(aContext).pop(target),
          child: Text('items.merge_action'.tr()),
        ),
      ],
    );
  }
}
