import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'routine_style.dart';

const List<int> _durations = [15, 30, 60, 120, 240];
const int _defaultMinutes = 60;
const int _snapMinutes = 15;
const int _maxNoteLen = 200;

DateTime snapToQuarter(DateTime aTs)
{
  final local = aTs.toLocal();
  final minute = (local.minute / _snapMinutes).floor() * _snapMinutes;
  return DateTime(local.year, local.month, local.day, local.hour, minute);
}

Future<bool> openNewBlock(
  BuildContext aContext,
  WidgetRef aRef, {
  required DateTime aStart,
  String? aPersonId,
  required String aPersonName,
}) async
{
  final draft = await showDialog<_BlockDraft>(
    context: aContext,
    builder: (_) => _NewBlockDialog(start: snapToQuarter(aStart), personName: aPersonName),
  );
  if (draft == null || !aContext.mounted)
  {
    return false;
  }
  try
  {
    await aRef.read(apiProv).createMark(
          draft.status,
          aNote: draft.note,
          aStartTs: draft.start,
          aEndTs: draft.end,
          aPersonId: aPersonId,
        );
    aRef.read(routineRevisionProv.notifier).state++;
    if (aContext.mounted)
    {
      showInfoSnack(aContext, 'routine.block_created'.tr(args: [draft.status.label]));
    }
    return true;
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
    return false;
  }
}

class _BlockDraft
{
  final RoutineStatus status;
  final DateTime start;
  final DateTime end;
  final String note;

  const _BlockDraft(this.status, this.start, this.end, this.note);
}

class _NewBlockDialog extends StatefulWidget
{
  final DateTime start;
  final String personName;

  const _NewBlockDialog({required this.start, required this.personName});

  @override
  State<_NewBlockDialog> createState() => _NewBlockDialogState();
}

class _NewBlockDialogState extends State<_NewBlockDialog>
{
  final _noteCtrl = TextEditingController();
  RoutineStatus _status = RoutineStatus.other;
  late DateTime _start = widget.start;
  int _minutes = _defaultMinutes;

  @override
  void dispose()
  {
    _noteCtrl.dispose();
    super.dispose();
  }

  DateTime get _end => _start.add(Duration(minutes: _minutes));

  String? get _error
  {
    final now = DateTime.now();
    if (_start.isBefore(now.subtract(const Duration(days: maxMarkPastDays))))
    {
      return 'routine.block_too_old'.tr();
    }
    if (_end.isAfter(now.add(const Duration(hours: maxMarkFutureHours))))
    {
      return 'routine.block_too_far'.tr();
    }
    return null;
  }

  Future<void> _pickDate() async
  {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(_start.year, _start.month, _start.day),
      firstDate: DateTime(now.year, now.month, now.day - maxMarkPastDays),
      lastDate: DateTime(now.year, now.month, now.day + 1),
    );
    if (picked != null && mounted)
    {
      setState(() => _start = DateTime(picked.year, picked.month, picked.day, _start.hour, _start.minute));
    }
  }

  Future<void> _pickTime() async
  {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (picked != null && mounted)
    {
      setState(() => _start = DateTime(_start.year, _start.month, _start.day, picked.hour, picked.minute));
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final error = _error;
    final locale = aContext.locale.toLanguageTag();

    return AlertDialog(
      scrollable: true,
      title: Text('routine.new_block'.tr(args: [widget.personName])),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final status in RoutineStatus.values)
                  ChoiceChip(
                    key: ValueKey('block.status.${status.name}'),
                    showCheckmark: false,
                    avatar: Icon(status.icon, size: 16, color: status.colorOf(aContext)),
                    label: Text(status.label),
                    selected: _status == status,
                    onSelected: (_) => setState(() => _status = status),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('block.date'),
                  onPressed: _pickDate,
                  icon: const Icon(AppIcons.calendar, size: 16),
                  label: Text(DateFormat.MMMEd(locale).format(_start)),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('block.time'),
                  onPressed: _pickTime,
                  icon: const Icon(AppIcons.clock, size: 16),
                  label: Text('routine.start_at'.tr(args: [formatClock(aContext, _start)])),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final minutes in _durations)
                  ChoiceChip(
                    key: ValueKey('block.minutes.$minutes'),
                    showCheckmark: false,
                    label: Text(formatDuration(Duration(minutes: minutes))),
                    selected: _minutes == minutes,
                    onSelected: (_) => setState(() => _minutes = minutes),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${formatClock(aContext, _start)}–${formatClock(aContext, _end)}',
              style: TextStyle(fontSize: 12, color: palette.inkMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtrl,
              inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLen)],
              decoration: InputDecoration(labelText: 'routine.note'.tr(), border: const OutlineInputBorder(), isDense: true),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error, style: TextStyle(fontSize: 12, color: palette.danger)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('block.save'),
          onPressed: error != null ? null : () => Navigator.of(aContext).pop(_BlockDraft(_status, _start, _end, _noteCtrl.text)),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}
