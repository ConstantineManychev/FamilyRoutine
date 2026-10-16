import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../planner/planner_common.dart';
import '../routine/routine_style.dart' as routine_style;
import '../routine/dash_card.dart';
import 'training_format.dart';
import 'training_revision.dart';
import '../common/app_theme.dart';

class NextWorkoutCard extends ConsumerStatefulWidget
{
  final Widget? menu;

  const NextWorkoutCard({super.key, this.menu});

  @override
  ConsumerState<NextWorkoutCard> createState() => _NextWorkoutCardState();
}

class _NextWorkoutCardState extends ConsumerState<NextWorkoutCard>
{
  TrainingPlan? _plan;
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
      final plan = await ref.read(apiProv).getTrainingPlan(aDays: 7);
      if (mounted)
      {
        setState(()
        {
          _plan = plan;
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

  Future<void> _open(String aPath) async
  {
    await context.push(aPath);
    await _load();
  }

  Future<void> _start(String aDayId) async
  {
    setState(() => _isBusy = true);
    try
    {
      final session = await ref.read(apiProv).startSession(aDayId);
      if (mounted)
      {
        notifyTrainingChanged(ref);
        await _open('/app/training/sessions/${session.id}');
      }
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
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(trainingRevisionProv, (_, __) => _load());

    return DashCard(
      title: Text('dashboard.widget_next_workout'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      menu: widget.menu,
      actions: [
        TextButton(onPressed: () => _open('/app/training'), child: Text('training.all_workouts'.tr())),
      ],
      child: _buildBody(aContext),
    );
  }

  Widget _buildBody(BuildContext aContext)
  {
    final plan = _plan;
    if (plan == null)
    {
      return _error != null
          ? Text(errorText(_error!), style: TextStyle(color: context.palette.inkMuted))
          : const LinearProgressIndicator();
    }

    final activeSessionId = plan.activeSessionId;
    if (activeSessionId != null)
    {
      return Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('training.in_progress'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
          FilledButton(onPressed: () => _open('/app/training/sessions/$activeSessionId'), child: Text('training.continue'.tr())),
        ],
      );
    }

    final slot = plan.nextSlot;
    if (slot != null)
    {
      return _buildSlot(aContext, plan, slot);
    }

    final next = plan.next;
    if (next == null)
    {
      return Text('training.no_program_hint'.tr(), style: TextStyle(color: context.palette.inkMuted));
    }

    final date = next.date;
    final isToday = date == null || DateUtils.isSameDay(date, DateTime.now());
    final last = plan.lastSession;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isToday ? 'training.next_today'.tr(args: [next.dayName]) : 'training.next_on'.tr(args: [next.dayName, plannedDateLabel(aContext, date)]),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        if (plan.program != null) Text(plan.program!.name, style: TextStyle(color: context.palette.inkSecondary)),
        if (last != null)
          Text(
            'training.last_workout'.tr(args: [
              last.dayName ?? 'training.free_workout'.tr(),
              DateFormat.MMMd(aContext.locale.toLanguageTag()).format(last.startedTs),
            ]),
            style: TextStyle(color: context.palette.inkMuted, fontSize: 13),
          ),
        if (isToday) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isBusy ? null : () => _start(next.dayId),
            icon: const Icon(AppIcons.dumbbell, size: 18),
            label: Text('training.start_day'.tr(args: [next.dayName])),
          ),
        ],
      ],
    );
  }

  Future<void> _startSlot(PlanSlot aSlot) async
  {
    setState(() => _isBusy = true);
    await startTrainingSlot(context, ref, aSlot.eventId, aSlot.occDate);
    if (mounted)
    {
      setState(() => _isBusy = false);
      await _load();
    }
  }

  Widget _buildSlot(BuildContext aContext, TrainingPlan aPlan, PlanSlot aSlot)
  {
    final localeTag = aContext.locale.toLanguageTag();
    final start = routine_style.formatClock(aContext, aSlot.startTs);
    final isToday = DateUtils.isSameDay(aSlot.startTs, DateTime.now());
    final String when;
    if (!isToday)
    {
      when = 'planner.slot_on'.tr(args: [DateFormat.MMMEd(localeTag).format(aSlot.startTs), start]);
    }
    else if (aSlot.timing == PlanTiming.window)
    {
      when = 'planner.slot_window_today'.tr(args: [start, routine_style.formatClock(aContext, aSlot.endTs)]);
    }
    else
    {
      when = 'planner.slot_today'.tr(args: [start]);
    }
    final dayName = aSlot.dayName ?? aPlan.next?.dayName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(when, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        Text(
          [aSlot.title, if (dayName != null && dayName != aSlot.title) dayName].join(' · '),
          style: TextStyle(color: context.palette.inkSecondary),
        ),
        if (isToday) ...[
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isBusy ? null : () => _startSlot(aSlot),
            icon: const Icon(AppIcons.dumbbell, size: 18),
            label: Text('planner.start_training'.tr()),
          ),
        ],
      ],
    );
  }
}
