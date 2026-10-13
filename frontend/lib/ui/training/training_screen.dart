import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'training_format.dart';
import 'training_revision.dart';

const double _contentMaxWidth = 960;
const Color _borderColor = Color(0xFFE5E7EB);
const int _upcomingLimit = 10;

class TrainingScreen extends ConsumerStatefulWidget
{
  const TrainingScreen({super.key});

  @override
  ConsumerState<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends ConsumerState<TrainingScreen>
{
  TrainingPlan? _plan;
  List<ProgramListItem> _programs = const [];
  List<SessionSummary> _sessions = const [];
  Object? _loadError;
  bool _isBusy = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    setState(() => _loadError = null);
    try
    {
      final api = ref.read(apiProv);
      final plan = await api.getTrainingPlan();
      final programs = await api.getPrograms();
      final sessions = await api.getSessions();
      if (mounted)
      {
        setState(()
        {
          _plan = plan;
          _programs = programs;
          _sessions = sessions;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
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

  Future<void> _start(String? aDayId) async
  {
    await _run(() async
    {
      final session = await ref.read(apiProv).startSession(aDayId);
      if (mounted)
      {
        notifyTrainingChanged(ref);
        await context.push('/app/training/sessions/${session.id}');
        await _load();
      }
    });
  }

  Future<void> _chooseToday() async
  {
    final program = _plan?.program;
    if (program == null)
    {
      return;
    }
    await _run(() async
    {
      final full = await ref.read(apiProv).getProgram(program.id);
      if (!mounted)
      {
        return;
      }
      final dayId = await showDialog<String>(
        context: context,
        builder: (aDialogContext) => SimpleDialog(
          title: Text('training.choose_today'.tr()),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('training.choose_today_hint'.tr(), style: const TextStyle(color: inkSecondary)),
            ),
            for (final day in full.days)
              SimpleDialogOption(
                onPressed: () => Navigator.of(aDialogContext).pop(day.id),
                child: Text(day.name),
              ),
          ],
        ),
      );
      if (dayId != null)
      {
        await ref.read(apiProv).setTrainingToday(dayId);
        await _load();
      }
    });
  }

  Future<void> _activate(ProgramListItem aProgram) async
  {
    await _run(() async
    {
      await ref.read(apiProv).activateProgram(aProgram.id);
      await _load();
    });
  }

  Future<void> _openEditor(String? aProgramId) async
  {
    await context.push(aProgramId == null ? '/app/training/programs/new' : '/app/training/programs/$aProgramId');
    await _load();
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(trainingRevisionProv, (_, __) => _load());
    final plan = _plan;
    if (plan == null)
    {
      return _loadError != null
          ? ErrorRetry(error: _loadError!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: screenPadding(aContext),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ScreenHeader(
                  title: 'training.title'.tr(),
                  actions: [
                    OutlinedButton.icon(
                      onPressed: _isBusy ? null : () => _openEditor(null),
                      icon: const Icon(AppIcons.plus, size: 18),
                      label: Text('training.new_program'.tr()),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildNext(aContext, plan),
                if (plan.upcoming.length > 1) ...[
                  const SizedBox(height: 16),
                  _buildUpcoming(aContext, plan),
                ],
                const SizedBox(height: 24),
                _buildPrograms(aContext),
                const SizedBox(height: 24),
                _buildHistory(aContext),
                if (_isBusy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(List<Widget> aChildren)
  {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _borderColor)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: aChildren),
      ),
    );
  }

  Widget _buildNext(BuildContext aContext, TrainingPlan aPlan)
  {
    final activeSessionId = aPlan.activeSessionId;
    if (activeSessionId != null)
    {
      return _card([
        Text('training.in_progress'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () async
            {
              await context.push('/app/training/sessions/$activeSessionId');
              await _load();
            },
            icon: const Icon(AppIcons.dumbbell, size: 18),
            label: Text('training.continue'.tr()),
          ),
        ),
      ]);
    }

    final program = aPlan.program;
    final next = aPlan.next;
    if (program == null || next == null)
    {
      return _card([
        Text('training.no_program'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('training.no_program_hint'.tr(), style: const TextStyle(color: inkSecondary)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _isBusy ? null : () => _openEditor(null),
              icon: const Icon(AppIcons.plus, size: 18),
              label: Text('training.new_program'.tr()),
            ),
            OutlinedButton(onPressed: _isBusy ? null : () => _start(null), child: Text('training.free_workout'.tr())),
          ],
        ),
      ]);
    }

    final date = next.date;
    final isToday = date == null || DateUtils.isSameDay(date, DateTime.now());
    final title = isToday
        ? 'training.next_today'.tr(args: [next.dayName])
        : 'training.next_on'.tr(args: [next.dayName, plannedDateLabel(aContext, date)]);

    return _card([
      Text(program.name, style: const TextStyle(color: inkSecondary)),
      const SizedBox(height: 4),
      Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      if (next.isOverdue) ...[
        const SizedBox(height: 4),
        Text('training.overdue'.tr(), style: TextStyle(color: Colors.orange.shade800)),
      ],
      if (!isToday) ...[
        const SizedBox(height: 4),
        Text('training.rest_today'.tr(), style: const TextStyle(color: inkSecondary)),
      ],
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            onPressed: _isBusy ? null : () => _start(next.dayId),
            icon: const Icon(AppIcons.dumbbell, size: 18),
            label: Text('training.start_day'.tr(args: [next.dayName])),
          ),
          OutlinedButton(onPressed: _isBusy ? null : _chooseToday, child: Text('training.other_day'.tr())),
          TextButton(onPressed: _isBusy ? null : () => _start(null), child: Text('training.free_workout'.tr())),
        ],
      ),
    ]);
  }

  Widget _buildUpcoming(BuildContext aContext, TrainingPlan aPlan)
  {
    final items = aPlan.upcoming.take(_upcomingLimit).toList();
    final isQueue = items.every((aItem) => aItem.date == null);

    return _card([
      Text('training.upcoming'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      if (isQueue)
        Text(items.map((aItem) => aItem.dayName).join(' → '), style: const TextStyle(color: inkSecondary))
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in items)
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('${plannedDateLabel(aContext, item.date!)} · ${item.dayName}'),
              ),
          ],
        ),
    ]);
  }

  Widget _buildPrograms(BuildContext aContext)
  {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('training.programs'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_programs.isEmpty)
          Text('training.no_programs'.tr(), style: const TextStyle(color: inkMuted))
        else
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            semanticContainer: false,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _borderColor)),
            child: Column(
              children: [
                for (final program in _programs)
                  ListTile(
                    onTap: () => _openEditor(program.id),
                    leading: Icon(program.isActive ? AppIcons.checkCircle : AppIcons.dumbbell, color: program.isActive ? Colors.green : inkMuted),
                    title: Text(program.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      'training.mode_${program.mode.name}'.tr(),
                      'training.days_count'.plural(program.dayCount),
                      if (program.isActive) 'training.active'.tr(),
                    ].join(' · ')),
                    trailing: program.isActive
                        ? null
                        : TextButton(onPressed: _isBusy ? null : () => _activate(program), child: Text('training.activate'.tr())),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildHistory(BuildContext aContext)
  {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('training.history'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (_sessions.isEmpty)
          Text('training.no_history'.tr(), style: const TextStyle(color: inkMuted))
        else
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            semanticContainer: false,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _borderColor)),
            child: Column(
              children: [
                for (final session in _sessions)
                  ListTile(
                    onTap: () async
                    {
                      await context.push('/app/training/sessions/${session.id}');
                      await _load();
                    },
                    title: Text(session.dayName ?? 'training.free_workout'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(sessionSubtitle(aContext, session)),
                    trailing: const Icon(AppIcons.chevronRight, size: 18),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
