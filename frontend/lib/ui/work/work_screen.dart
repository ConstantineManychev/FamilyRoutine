import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'task_actions.dart';
import 'task_sheet.dart';
import 'task_tile.dart';
import 'work_format.dart';

const double _contentMaxWidth = 720;
const int _maxDaysAway = 365;

DateTime _dayOnly(DateTime aValue) => DateTime(aValue.year, aValue.month, aValue.day);

class WorkScreen extends ConsumerStatefulWidget
{
  final DateTime? initialDate;

  const WorkScreen({super.key, this.initialDate});

  @override
  ConsumerState<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends ConsumerState<WorkScreen>
{
  late DateTime _date = _dayOnly(widget.initialDate ?? DateTime.now());
  WorkDay? _day;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    final date = _date;
    try
    {
      final day = await ref.read(apiProv).getWorkDay(date);
      if (mounted && date == _date)
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
      if (mounted && date == _date)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _setDate(DateTime aDate)
  {
    setState(()
    {
      _date = _dayOnly(aDate);
      _day = null;
      _error = null;
    });
    _load();
  }

  Future<void> _pickDate() async
  {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: _maxDaysAway)),
      lastDate: now.add(const Duration(days: _maxDaysAway)),
    );
    if (picked != null && mounted)
    {
      _setDate(picked);
    }
  }

  Future<void> _toggle(WorkTask aTask) async
  {
    if (aTask.isDoneOn(_date))
    {
      await reopenTaskFlow(context, ref, aTask, _date);
    }
    else
    {
      await completeTaskFlow(context, ref, aTask, _date);
    }
  }

  Widget _dateBar(BuildContext aContext)
  {
    final isToday = _date == _dayOnly(DateTime.now());
    final label = DateFormat.MMMMEEEEd(aContext.locale.toLanguageTag()).format(_date);
    return Row(
      children: [
        IconButton(
          tooltip: 'work.prev_day'.tr(),
          onPressed: () => _setDate(_date.subtract(const Duration(days: 1))),
          icon: const Icon(AppIcons.chevronLeft),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: _pickDate,
            icon: const Icon(AppIcons.calendar, size: 18),
            label: Text(isToday ? '${'work.today'.tr()}, $label' : label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
        if (!isToday) TextButton(onPressed: () => _setDate(DateTime.now()), child: Text('work.today'.tr())),
        IconButton(
          tooltip: 'work.next_day'.tr(),
          onPressed: () => _setDate(_date.add(const Duration(days: 1))),
          icon: const Icon(AppIcons.chevronRight),
        ),
      ],
    );
  }

  Widget _section(BuildContext aContext, {required String aTitle, required String aHint, required List<WorkTask> aTasks, required TaskKind aKind})
  {
    final palette = aContext.palette;
    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const SizedBox(width: 8),
                Icon(aKind == TaskKind.general ? AppIcons.history : AppIcons.calendar, size: 18, color: palette.inkSecondary),
                const SizedBox(width: 8),
                Expanded(child: Text(aTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                IconButton(
                  key: ValueKey('work.add.${aKind.name}'),
                  tooltip: 'work.add_kind_${aKind.name}'.tr(),
                  onPressed: () => createTaskFlow(context, ref, _date, aKind: aKind),
                  icon: Icon(AppIcons.plus, color: aContext.colors.primary),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
              child: Text(aHint, style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            ),
            if (aTasks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text('work.empty'.tr(), style: TextStyle(color: palette.inkMuted)),
              )
            else
              for (final task in aTasks)
                TaskTile(
                  task: task,
                  day: _date,
                  onOpen: () => openTaskSheet(context, task.id, _date),
                  onToggle: () => _toggle(task),
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(workRevisionProv, (_, __) => _load());
    final day = _day;
    final Widget body;
    if (_error != null)
    {
      body = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (day == null)
    {
      body = const Center(child: CircularProgressIndicator());
    }
    else
    {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: screenPadding(aContext),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _section(
                      aContext,
                      aTitle: 'work.day_tasks'.tr(),
                      aHint: 'work.kind_day_hint'.tr(),
                      aTasks: day.day,
                      aKind: TaskKind.day,
                    ),
                    const SizedBox(height: 16),
                    _section(
                      aContext,
                      aTitle: 'work.general_tasks'.tr(),
                      aHint: 'work.kind_general_hint'.tr(),
                      aTasks: day.general,
                      aKind: TaskKind.general,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return SubPage(
      title: 'work.title'.tr(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: _dateBar(aContext)),
          Expanded(child: body),
        ],
      ),
    );
  }
}
