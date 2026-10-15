import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'item_form.dart';
import 'item_prices_section.dart';
import 'items_screen.dart';
import '../common/app_theme.dart';

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
  late final ItemDraft _draft = ItemDraft(aBarcode: widget.initialBarcode);
  DictItemDto? _item;
  bool _isLoading = false;
  bool _isSaving = false;
  Object? _loadError;

  bool get _isEdit => widget.itemId != null;

  @override
  void initState()
  {
    super.initState();
    if (_isEdit)
    {
      _load();
    }
  }

  @override
  void dispose()
  {
    _draft.dispose();
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
    _draft.load(aItem);
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
    final error = _draft.validate();
    if (error != null)
    {
      showInfoSnack(context, error);
      return;
    }

    setState(() => _isSaving = true);
    try
    {
      final saved = await ref.read(apiProv).saveItem(widget.itemId, _draft.payload());
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
        context.pushReplacement('/app/items/${saved.id}');
      }
    }
    catch (aError)
    {
      final existing = _isEdit ? null : await findDuplicateItem(ref, aError, _draft).catchError((_) => null);
      if (!mounted)
      {
        return;
      }
      if (existing != null && await confirmUseExisting(context, existing))
      {
        if (mounted)
        {
          context.pushReplacement('/app/items/${existing.id}');
        }
        return;
      }
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
        finishPage(context, '/app/items');
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
        context.pushReplacement('/app/items/${merged.id}');
      }
    });
  }

  Widget _hint(IconData aIcon, String aText, Color aColor)
  {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(aIcon, size: 18, color: aColor),
          const SizedBox(width: 8),
          Expanded(child: Text(aText, style: TextStyle(color: context.palette.inkSecondary))),
        ],
      ),
    );
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
    final palette = aContext.palette;
    final isEditable = !_isEdit || (item?.isEditable ?? false);
    final isIdentityEnabled = !_isEdit || (item?.canEditIdentity ?? false);

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'items.item'.tr() : 'items.new'.tr(),
          actions: [
            if (item != null && item.canMerge)
              IconButton(
                tooltip: 'items.merge'.tr(),
                icon: const Icon(AppIcons.merge),
                onPressed: _isSaving ? null : _merge,
              ),
            if (item != null && item.canDelete)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: palette.danger),
                onPressed: _isSaving ? null : _delete,
                icon: const Icon(AppIcons.trash2, size: 18),
                label: Text('common.delete'.tr()),
              ),
            if (isEditable)
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: const Icon(AppIcons.save, size: 18),
                label: Text('common.save'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (item != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Icon(itemOwnerIcon(item.ownerKind), size: 16, color: palette.inkMuted),
                const SizedBox(width: 6),
                Text('items.owner_label'.tr(args: [itemOwnerLabel(item)]), style: TextStyle(color: palette.inkSecondary)),
              ],
            ),
          ),
        if (item != null && !item.isEditable)
          _hint(AppIcons.lock, 'items.readonly_hint'.tr(), palette.inkMuted)
        else if (item != null && item.isAdminEdit)
          _hint(AppIcons.shieldCheck, 'items.admin_hint'.tr(), palette.warning)
        else if (item != null && item.isInUse)
          _hint(AppIcons.lock, 'items.in_use_hint'.tr(), palette.warning)
        else if (!_isEdit)
          _hint(AppIcons.globe, 'items.public_hint'.tr(), palette.inkMuted),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ItemFormFields(
            draft: _draft,
            isIdentityEnabled: isIdentityEnabled,
            isNutritionEnabled: isEditable,
            isAutoLookup: !_isEdit,
            currentItemId: widget.itemId,
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

  bool _isCompatible(DictItemDto aItem) => aItem.id != widget.source.id && aItem.unit == widget.source.unit;

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
      scrollable: true,
      title: Text('items.merge'.tr()),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('items.merge_hint'.tr(args: [widget.source.name]), style: TextStyle(color: context.palette.inkSecondary)),
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
                  ? Center(child: Text('common.no_data'.tr(), style: TextStyle(color: context.palette.inkMuted)))
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
                                    itemOwnerLabel(aItem),
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
