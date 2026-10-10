import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';

const int maxItemNameLen = 200;

IconData itemKindIcon(ItemKind aKind)
{
  return switch (aKind)
  {
    ItemKind.product => AppIcons.package,
    ItemKind.service => AppIcons.wrench,
    ItemKind.food => AppIcons.apple,
  };
}

String itemKindLabel(ItemKind aKind) => 'items.kind_${aKind.name}'.tr();

String itemUnitLabel(ItemUnit aUnit) => 'items.unit_${aUnit.wire}'.tr();

String itemUnitShort(ItemUnit aUnit) => 'items.unit_short_${aUnit.wire}'.tr();

class ItemFormFields extends StatelessWidget
{
  final TextEditingController nameCtrl;
  final ItemKind kind;
  final ItemUnit unit;
  final bool isEnabled;
  final bool isNameFocused;
  final ValueChanged<ItemKind> onKindChanged;
  final ValueChanged<ItemUnit> onUnitChanged;

  const ItemFormFields({
    super.key,
    required this.nameCtrl,
    required this.kind,
    required this.unit,
    required this.onKindChanged,
    required this.onUnitChanged,
    this.isEnabled = true,
    this.isNameFocused = false,
  });

  @override
  Widget build(BuildContext aContext)
  {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: nameCtrl,
          enabled: isEnabled,
          autofocus: isNameFocused,
          inputFormatters: [LengthLimitingTextInputFormatter(maxItemNameLen)],
          decoration: InputDecoration(labelText: 'items.name'.tr(), border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        SegmentedButton<ItemKind>(
          segments: ItemKind.values
              .map((aKind) => ButtonSegment(value: aKind, icon: Icon(itemKindIcon(aKind), size: 16), label: Text(itemKindLabel(aKind))))
              .toList(),
          selected: {kind},
          showSelectedIcon: false,
          onSelectionChanged: isEnabled ? (aSelected) => onKindChanged(aSelected.first) : null,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<ItemUnit>(
          initialValue: unit,
          decoration: InputDecoration(
            labelText: 'items.unit'.tr(),
            helperText: 'items.unit_hint'.tr(),
            border: const OutlineInputBorder(),
          ),
          items: ItemUnit.values
              .map((aUnit) => DropdownMenuItem(value: aUnit, child: Text('${itemUnitLabel(aUnit)} (${itemUnitShort(aUnit)})')))
              .toList(),
          onChanged: isEnabled ? (aValue) => onUnitChanged(aValue ?? unit) : null,
        ),
      ],
    );
  }
}

class ItemCreateDialog extends ConsumerStatefulWidget
{
  final String initialName;

  const ItemCreateDialog({super.key, required this.initialName});

  @override
  ConsumerState<ItemCreateDialog> createState() => _ItemCreateDialogState();
}

class _ItemCreateDialogState extends ConsumerState<ItemCreateDialog>
{
  late final TextEditingController _nameCtrl = TextEditingController(text: widget.initialName.trim());
  ItemKind _kind = ItemKind.product;
  ItemUnit _unit = ItemUnit.piece;
  bool _isSaving = false;

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async
  {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty)
    {
      showInfoSnack(context, 'items.err_name'.tr());
      return;
    }

    setState(() => _isSaving = true);

    try
    {
      final item = await ref.read(apiProv).saveItem(null, DictItemDto.payload(name, _kind, _unit));
      if (mounted)
      {
        Navigator.of(context).pop(item);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('items.new'.tr()),
      content: SizedBox(
        width: 420,
        child: ItemFormFields(
          nameCtrl: _nameCtrl,
          kind: _kind,
          unit: _unit,
          isNameFocused: true,
          onKindChanged: (aKind) => setState(() => _kind = aKind),
          onUnitChanged: (aUnit) => setState(() => _unit = aUnit),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(onPressed: _isSaving ? null : _save, child: Text('items.add_to_dict'.tr())),
      ],
    );
  }
}

Future<DictItemDto?> showItemCreateDialog(BuildContext aContext, String aInitialName)
{
  return showDialog<DictItemDto>(context: aContext, builder: (_) => ItemCreateDialog(initialName: aInitialName));
}
