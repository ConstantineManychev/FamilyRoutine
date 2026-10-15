import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import 'training_format.dart';
import '../common/app_theme.dart';

const int _shownSessions = 5;

class PersonTrainingCard extends ConsumerStatefulWidget
{
  final String personId;

  const PersonTrainingCard({super.key, required this.personId});

  @override
  ConsumerState<PersonTrainingCard> createState() => _PersonTrainingCardState();
}

class _PersonTrainingCardState extends ConsumerState<PersonTrainingCard>
{
  PersonTraining? _training;
  Object? _error;

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
      final training = await ref.read(apiProv).getPersonTraining(widget.personId);
      if (mounted)
      {
        setState(()
        {
          _training = training;
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

  void _open(String aSessionId) => context.push('/app/people/${widget.personId}/sessions/$aSessionId');

  @override
  Widget build(BuildContext aContext)
  {
    final training = _training;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.palette.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('training.title'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_error != null)
              ErrorRetry(error: _error!, onRetry: _load)
            else if (training == null)
              const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
            else
              ..._buildBody(aContext, training),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBody(BuildContext aContext, PersonTraining aTraining)
  {
    final program = aTraining.program;
    final plan = aTraining.plan;
    final next = plan.next;
    final sessions = aTraining.sessions.take(_shownSessions).toList();

    return [
      if (program == null)
        Text('training.no_program'.tr(), style: TextStyle(color: context.palette.inkMuted))
      else ...[
        Text(program.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text(
          [
            'training.mode_${program.mode.name}'.tr(),
            'training.days_count'.plural(program.days.length),
            program.days.map((aDay) => aDay.name).join(', '),
          ].join(' · '),
          style: TextStyle(color: context.palette.inkSecondary),
        ),
      ],
      if (plan.activeSessionId != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(AppIcons.activity, color: context.palette.positive),
          title: Text('training.in_progress'.tr()),
          trailing: const Icon(AppIcons.chevronRight, size: 18),
          onTap: () => _open(plan.activeSessionId!),
        )
      else if (next != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            next.date == null || DateUtils.isSameDay(next.date, DateTime.now())
                ? 'training.next_today'.tr(args: [next.dayName])
                : 'training.next_on'.tr(args: [next.dayName, plannedDateLabel(aContext, next.date!)]),
          ),
        ),
      const SizedBox(height: 12),
      Text('training.history'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
      if (sessions.isEmpty)
        Text('training.no_history'.tr(), style: TextStyle(color: context.palette.inkMuted))
      else
        for (final session in sessions)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(session.dayName ?? 'training.free_workout'.tr()),
            subtitle: Text(sessionSubtitle(aContext, session)),
            trailing: const Icon(AppIcons.chevronRight, size: 18),
            onTap: () => _open(session.id),
          ),
    ];
  }
}
