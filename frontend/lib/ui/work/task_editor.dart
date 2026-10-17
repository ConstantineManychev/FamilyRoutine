import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'work_format.dart';

const int maxTaskTitleLen = 200;
const int maxTaskNoteLen = 2000;
const int maxReportLen = 2000;

Future<TaskDraft?> showTaskEditor(BuildContext aContext, {WorkTask? aTask, required DateTime aDate, TaskKind aKind = TaskKind.day})
{
  return showDialog<TaskDraft>(
    context: aContext,
    builder: (_) => TaskEditorDialog(task: aTask, date: aDate, kind: aKind),
  );
}

class TaskEditorDialog extends StatefulWidget
{
  final WorkTask? task;
  final DateTime date;
  final TaskKind kind;

  const TaskEditorDialog({super.key, this.task, required this.date, this.kind = TaskKind.day});

  @override
  State<TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<TaskEditorDialog>
{
  late final _titleCtrl = TextEditingController(text: widget.task?.title ?? '');
  late final _noteCtrl = TextEditingController(text: widget.task?.note ?? '');
  late TaskKind _kind = widget.task?.kind ?? widget.kind;
  late DateTime _date = widget.task?.startOn ?? widget.date;

  @override
  void dispose()
  {
    _titleCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  bool get _isValid => _titleCtrl.text.trim().isNotEmpty;

  Future<void> _pickDate() async
  {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && mounted)
    {
      setState(() => _date = DateUtils.dateOnly(picked));
    }
  }

  void _save()
  {
    Navigator.of(context).pop(TaskDraft(kind: _kind, title: _titleCtrl.text, note: _noteCtrl.text, date: _date));
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;

    return AlertDialog(
      scrollable: true,
      title: Text(widget.task == null ? 'work.new_task'.tr() : 'work.edit_task'.tr()),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('task.title'),
              controller: _titleCtrl,
              autofocus: widget.task == null,
              inputFormatters: [LengthLimitingTextInputFormatter(maxTaskTitleLen)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: 'work.task_title'.tr(), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('task.note'),
              controller: _noteCtrl,
              minLines: 2,
              maxLines: 5,
              inputFormatters: [LengthLimitingTextInputFormatter(maxTaskNoteLen)],
              decoration: InputDecoration(labelText: 'work.note'.tr(), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            SegmentedButton<TaskKind>(
              segments: [
                ButtonSegment(value: TaskKind.day, label: Text(taskKindLabel(TaskKind.day))),
                ButtonSegment(value: TaskKind.general, label: Text(taskKindLabel(TaskKind.general))),
              ],
              selected: {_kind},
              showSelectedIcon: false,
              onSelectionChanged: (aSelected) => setState(() => _kind = aSelected.first),
            ),
            const SizedBox(height: 6),
            Text('work.kind_${_kind.name}_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('task.date'),
                onPressed: _pickDate,
                icon: const Icon(AppIcons.calendar, size: 16),
                label: Text(
                  (_kind == TaskKind.day ? 'work.date_day' : 'work.date_general').tr(args: [shortDate(aContext, _date)]),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('task.save'),
          onPressed: _isValid ? _save : null,
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}

Future<String?> showReportDialog(BuildContext aContext, {required String aTitle, required String aHint, bool aIsRequired = false})
{
  return showDialog<String>(
    context: aContext,
    builder: (_) => ReportDialog(title: aTitle, hint: aHint, isRequired: aIsRequired),
  );
}

class ReportDialog extends StatefulWidget
{
  final String title;
  final String hint;
  final bool isRequired;

  const ReportDialog({super.key, required this.title, required this.hint, this.isRequired = false});

  @override
  State<ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<ReportDialog>
{
  final _ctrl = TextEditingController();

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _isValid => !widget.isRequired || _ctrl.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: TextField(
          key: const ValueKey('task.report'),
          controller: _ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          inputFormatters: [LengthLimitingTextInputFormatter(maxReportLen)],
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: widget.isRequired ? 'work.report_required'.tr() : 'work.report_optional'.tr(),
            hintText: widget.hint,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('task.report_save'),
          onPressed: _isValid ? () => Navigator.of(aContext).pop(_ctrl.text.trim()) : null,
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}
