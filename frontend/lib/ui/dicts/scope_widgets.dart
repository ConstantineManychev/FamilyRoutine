import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/money.dart';

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

class FamilyBadge extends StatelessWidget
{
  final String name;

  const FamilyBadge({super.key, required this.name});

  @override
  Widget build(BuildContext aContext)
  {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(AppIcons.users, size: 12, color: Color(0xFF1D4ED8)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1D4ED8)),
            ),
          ),
        ],
      ),
    );
  }
}

class ScopeDropdown extends StatelessWidget
{
  final List<FamDto> fams;
  final String? familyId;
  final ValueChanged<String?> onChanged;

  const ScopeDropdown({super.key, required this.fams, required this.familyId, required this.onChanged});

  @override
  Widget build(BuildContext aContext)
  {
    return DropdownButtonFormField<String?>(
      initialValue: familyId,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'catalog.scope'.tr(),
        helperText: 'catalog.scope_hint'.tr(),
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
      items: [
        DropdownMenuItem<String?>(value: null, child: Text('catalog.scope_personal'.tr())),
        ...fams.map((aFam) => DropdownMenuItem<String?>(
              value: aFam.id,
              child: Text('catalog.scope_family'.tr(args: [aFam.name]), overflow: TextOverflow.ellipsis),
            )),
      ],
      onChanged: onChanged,
    );
  }
}

Future<String?> showShareToFamilyDialog(BuildContext aContext, List<FamDto> aFams, String aTitle)
{
  return showDialog<String>(
    context: aContext,
    builder: (_) => _ShareDialog(fams: aFams, title: aTitle),
  );
}

class _ShareDialog extends StatefulWidget
{
  final List<FamDto> fams;
  final String title;

  const _ShareDialog({required this.fams, required this.title});

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog>
{
  late String? _familyId = widget.fams.firstOrNull?.id;

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _familyId,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'dashboard.family'.tr(), border: const OutlineInputBorder()),
              items: widget.fams
                  .map((aFam) => DropdownMenuItem(value: aFam.id, child: Text(aFam.name, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (aValue) => setState(() => _familyId = aValue),
            ),
            const SizedBox(height: 12),
            Text('catalog.share_warning'.tr(), style: const TextStyle(color: inkSecondary)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: _familyId == null ? null : () => Navigator.of(aContext).pop(_familyId),
          child: Text('catalog.share_action'.tr()),
        ),
      ],
    );
  }
}
