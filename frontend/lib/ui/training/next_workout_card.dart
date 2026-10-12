import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import '../routine/dash_card.dart';
import 'training_format.dart';
import 'training_revision.dart';

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
          ? Text(errorText(_error!), style: const TextStyle(color: inkMuted))
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

    final next = plan.next;
    if (next == null)
    {
      return Text('training.no_program_hint'.tr(), style: const TextStyle(color: inkMuted));
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
        if (plan.program != null) Text(plan.program!.name, style: const TextStyle(color: inkSecondary)),
        if (last != null)
          Text(
            'training.last_workout'.tr(args: [
              last.dayName ?? 'training.free_workout'.tr(),
              DateFormat.MMMd(aContext.locale.toLanguageTag()).format(last.startedTs),
            ]),
            style: const TextStyle(color: inkMuted, fontSize: 13),
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
}
