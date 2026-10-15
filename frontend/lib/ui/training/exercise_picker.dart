import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import 'training_format.dart';
import '../common/app_theme.dart';
import '../common/page_frames.dart';

Future<DictExDto?> showExercisePicker(BuildContext aContext, List<DictExDto> aCatalog)
{
  return showDialog<DictExDto>(context: aContext, builder: (_) => _ExercisePicker(catalog: aCatalog));
}

class _ExercisePicker extends StatefulWidget
{
  final List<DictExDto> catalog;

  const _ExercisePicker({required this.catalog});

  @override
  State<_ExercisePicker> createState() => _ExercisePickerState();
}

class _ExercisePickerState extends State<_ExercisePicker>
{
  final _searchCtrl = TextEditingController();

  @override
  void dispose()
  {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    final query = _searchCtrl.text.trim().toLowerCase();
    final items = widget.catalog
        .map((aExercise) => (exercise: aExercise, name: exerciseDisplayName(aExercise)))
        .where((aItem) => query.isEmpty || aItem.name.toLowerCase().contains(query))
        .toList()
      ..sort((aLeft, aRight) => aLeft.name.compareTo(aRight.name));

    return AlertDialog(
      title: Text('training.pick_exercise'.tr()),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 460,
        height: dialogListHeight(aContext, 480),
        child: Column(
          children: [
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixIcon: const Icon(AppIcons.search, size: 18),
                labelText: 'training.search_exercise'.tr(),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text('training.no_exercises_found'.tr(), style: TextStyle(color: context.palette.inkMuted)))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (_, aIndex) => ListTile(
                        dense: true,
                        title: Text(items[aIndex].name),
                        subtitle: Text('exercises.types.${items[aIndex].exercise.exType}'.tr()),
                        onTap: () => Navigator.of(aContext).pop(items[aIndex].exercise),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
      ],
    );
  }
}
