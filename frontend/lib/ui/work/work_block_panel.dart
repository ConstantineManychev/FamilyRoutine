import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../routine/routine_style.dart';
import 'task_actions.dart';
import 'task_sheet.dart';
import 'task_tile.dart';
import 'work_format.dart';

class WorkBlockPanel extends ConsumerStatefulWidget
{
  final String markId;
  final MarkWork work;
  final ValueChanged<String> onOpenAll;

  const WorkBlockPanel({super.key, required this.markId, required this.work, required this.onOpenAll});

  @override
  ConsumerState<WorkBlockPanel> createState() => _WorkBlockPanelState();
}

class _WorkBlockPanelState extends ConsumerState<WorkBlockPanel>
{
  late MarkWork _work = widget.work;

  DateTime get _day => _work.day.date;

  Future<void> _refresh() async
  {
    try
    {
      final details = await ref.read(apiProv).getMarkDetails(widget.markId);
      final work = details.work;
      if (mounted && work != null)
      {
        setState(() => _work = work);
      }
    }
    catch (_)
    {
      return;
    }
  }

  Future<void> _after(Future<Object?> aAction) async
  {
    final result = await aAction;
    if (result != null)
    {
      await _refresh();
    }
  }

  Future<void> _toggle(WorkTask aTask) async
  {
    if (aTask.isDoneOn(_day))
    {
      await _after(reopenTaskFlow(context, ref, aTask, _day));
    }
    else
    {
      await _after(completeTaskFlow(context, ref, aTask, _day, aMarkId: widget.markId));
    }
  }

  Future<void> _open(WorkTask aTask) async
  {
    await openTaskSheet(context, aTask.id, _day, aMarkId: widget.markId);
    await _refresh();
  }

  Widget _group(BuildContext aContext, String aTitle, List<WorkTask> aTasks)
  {
    if (aTasks.isEmpty)
    {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(aTitle, style: TextStyle(fontWeight: FontWeight.w700, color: aContext.palette.inkSecondary)),
        ),
        for (final task in aTasks)
          TaskTile(
            task: task,
            day: _day,
            onOpen: () => _open(task),
            onToggle: () => _toggle(task),
            onReport: task.isDoneOn(_day) ? null : () => _after(progressTaskFlow(context, ref, task, _day, aMarkId: widget.markId)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final day = _work.day;
    final logged = _work.logged;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(AppIcons.listChecks, size: 18, color: palette.inkSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'work.block_title'.tr(args: ['${day.openCount}']),
                key: const ValueKey('work.block.title'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        if (day.all.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('work.block_empty'.tr(), style: TextStyle(color: palette.inkMuted)),
          ),
        _group(aContext, 'work.day_tasks'.tr(), day.day),
        _group(aContext, 'work.general_tasks'.tr(), day.general),
        const SizedBox(height: 8),
        Text('work.block_logged'.tr(), style: TextStyle(fontWeight: FontWeight.w700, color: palette.inkSecondary)),
        const SizedBox(height: 4),
        if (logged.isEmpty)
          Text('work.block_logged_empty'.tr(), style: TextStyle(color: palette.inkMuted))
        else
          for (final entry in logged)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    eventIcon(entry.kind),
                    size: 16,
                    color: entry.kind == TaskEventKind.done ? palette.positive : palette.inkSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [
                        entry.taskTitle,
                        if (entry.report != null) entry.report!,
                      ].join(' — '),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(formatClock(aContext, entry.eventTs), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
                ],
              ),
            ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: [
            TextButton.icon(
              key: const ValueKey('work.block.add'),
              onPressed: () => _after(createTaskFlow(context, ref, _day)),
              icon: const Icon(AppIcons.plus, size: 16),
              label: Text('work.new_task'.tr()),
            ),
            TextButton.icon(
              key: const ValueKey('work.block.all'),
              onPressed: () => widget.onOpenAll(workPath(_day)),
              icon: const Icon(AppIcons.chevronRight, size: 16),
              label: Text('work.all_tasks'.tr()),
            ),
          ],
        ),
      ],
    );
  }
}
