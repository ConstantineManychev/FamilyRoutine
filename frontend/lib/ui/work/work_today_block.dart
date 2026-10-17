import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'task_actions.dart';
import 'task_sheet.dart';
import 'task_tile.dart';
import 'work_format.dart';

const int _shownTasks = 5;

class WorkTodayBlock extends ConsumerStatefulWidget
{
  const WorkTodayBlock({super.key});

  @override
  ConsumerState<WorkTodayBlock> createState() => _WorkTodayBlockState();
}

class _WorkTodayBlockState extends ConsumerState<WorkTodayBlock>
{
  WorkDay? _day;
  Object? _error;

  DateTime get _today
  {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

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
      final day = await ref.read(apiProv).getWorkDay(_today);
      if (mounted)
      {
        setState(()
        {
          _day = day;
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

  Future<void> _toggle(WorkTask aTask) async
  {
    if (aTask.isDoneOn(_today))
    {
      await reopenTaskFlow(context, ref, aTask, _today);
    }
    else
    {
      await completeTaskFlow(context, ref, aTask, _today);
    }
  }

  Future<void> _openAll() async
  {
    await context.push(workPath(_today));
    await _load();
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(workRevisionProv, (_, __) => _load());
    final day = _day;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (day == null)
    {
      content = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else
    {
      final open = day.all.where((aTask) => !aTask.isDoneOn(day.date)).toList();
      final done = day.all.length - open.length;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (open.isEmpty)
            BlockEmpty(day.all.isEmpty ? 'work.today_empty'.tr() : 'work.today_all_done'.tr())
          else
            for (final task in open.take(_shownTasks))
              TaskTile(
                task: task,
                day: day.date,
                onOpen: () => openTaskSheet(context, task.id, day.date),
                onToggle: () => _toggle(task),
              ),
          if (open.length > _shownTasks || done > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'work.today_summary'.tr(args: ['${open.length}', '$done']),
                style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
              ),
            ),
        ],
      );
    }

    return BlockCard(
      title: 'work.today_block'.tr(),
      onAdd: () => createTaskFlow(context, ref, _today),
      addTooltip: 'work.new_task'.tr(),
      onExpand: _openAll,
      child: content,
    );
  }
}
