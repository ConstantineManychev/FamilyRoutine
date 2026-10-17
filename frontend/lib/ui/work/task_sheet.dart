import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'task_actions.dart';
import 'work_format.dart';

Future<void> openTaskSheet(BuildContext aContext, String aTaskId, DateTime aDay, {String? aMarkId})
{
  return showModalBottomSheet<void>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TaskSheet(taskId: aTaskId, day: aDay, markId: aMarkId),
  );
}

class TaskSheet extends ConsumerStatefulWidget
{
  final String taskId;
  final DateTime day;
  final String? markId;

  const TaskSheet({super.key, required this.taskId, required this.day, this.markId});

  @override
  ConsumerState<TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends ConsumerState<TaskSheet>
{
  TaskDetails? _details;
  Object? _error;
  bool _isBusy = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    try
    {
      final details = await ref.read(apiProv).getTask(widget.taskId);
      if (mounted)
      {
        setState(()
        {
          _details = details;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  Future<void> _apply(Future<TaskDetails?> Function() aAction) async
  {
    setState(() => _isBusy = true);
    final details = await aAction();
    if (mounted)
    {
      setState(()
      {
        _isBusy = false;
        if (details != null)
        {
          _details = details;
        }
      });
    }
  }

  Future<void> _archive(WorkTask aTask) async
  {
    setState(() => _isBusy = true);
    final isArchived = await archiveTaskFlow(context, ref, aTask);
    if (!mounted)
    {
      return;
    }
    if (isArchived)
    {
      Navigator.of(context).pop();
    }
    else
    {
      setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final media = MediaQuery.of(aContext);
    final details = _details;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: details == null
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: _error != null
                  ? ErrorRetry(error: _error!, onRetry: _load)
                  : const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
            )
          : SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + media.padding.bottom),
              child: _buildContent(aContext, details),
            ),
    );
  }

  Widget _buildContent(BuildContext aContext, TaskDetails aDetails)
  {
    final palette = aContext.palette;
    final task = aDetails.task;
    final day = widget.day;
    final isActive = !task.isArchived && !_isBusy;
    final isDone = task.isDone;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isDone ? AppIcons.checkCircle : AppIcons.circleDot, color: isDone ? palette.positive : palette.inkSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                task.title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  decoration: isDone ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(task.kind == TaskKind.general ? AppIcons.history : AppIcons.calendar, size: 14),
              label: Text(taskKindLabel(task.kind)),
            ),
            Text(taskStatusLine(aContext, task, day), style: TextStyle(color: palette.inkSecondary)),
            if (task.isArchived) Text('work.archived'.tr(), style: TextStyle(color: palette.danger)),
          ],
        ),
        if (task.note != null) ...[
          const SizedBox(height: 8),
          Text(task.note!, style: TextStyle(color: palette.inkPrimary)),
        ],
        if (!task.isArchived) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!isDone)
                FilledButton.icon(
                  key: const ValueKey('task.done'),
                  onPressed: isActive ? () => _apply(() => completeTaskFlow(context, ref, task, day, aMarkId: widget.markId)) : null,
                  icon: const Icon(AppIcons.check, size: 16),
                  label: Text('work.mark_done'.tr()),
                )
              else
                OutlinedButton.icon(
                  key: const ValueKey('task.reopen'),
                  onPressed: isActive ? () => _apply(() => reopenTaskFlow(context, ref, task, day)) : null,
                  icon: const Icon(AppIcons.refreshCw, size: 16),
                  label: Text('work.reopen'.tr()),
                ),
              OutlinedButton.icon(
                key: const ValueKey('task.progress'),
                onPressed: isActive ? () => _apply(() => progressTaskFlow(context, ref, task, day, aMarkId: widget.markId)) : null,
                icon: const Icon(AppIcons.listChecks, size: 16),
                label: Text('work.add_report'.tr()),
              ),
              OutlinedButton.icon(
                key: const ValueKey('task.edit'),
                onPressed: isActive ? () => _apply(() => editTaskFlow(context, ref, task)) : null,
                icon: const Icon(AppIcons.pencil, size: 16),
                label: Text('work.edit'.tr()),
              ),
              IconButton(
                key: const ValueKey('task.archive'),
                tooltip: 'work.archive'.tr(),
                color: palette.danger,
                onPressed: isActive ? () => _archive(task) : null,
                icon: const Icon(AppIcons.trash2),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Text('work.history'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('work.history_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
        const SizedBox(height: 8),
        for (final event in aDetails.events.reversed) TaskEventTile(event: event),
      ],
    );
  }
}

class TaskEventTile extends StatelessWidget
{
  final TaskEvent event;

  const TaskEventTile({super.key, required this.event});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final report = event.report;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            eventIcon(event.kind),
            size: 18,
            color: event.kind == TaskEventKind.done ? palette.positive : palette.inkSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eventTitle(aContext, event), style: const TextStyle(fontWeight: FontWeight.w600)),
                if (report != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(report, style: TextStyle(color: palette.inkPrimary)),
                  ),
                Text(
                  [
                    eventStamp(aContext, event.eventTs),
                    if (event.statusMarkId != null) 'work.in_work_block'.tr(),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: palette.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
