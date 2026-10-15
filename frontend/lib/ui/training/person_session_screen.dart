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

const double _contentMaxWidth = 960;

class PersonSessionScreen extends ConsumerStatefulWidget
{
  final String personId;
  final String sessionId;

  const PersonSessionScreen({super.key, required this.personId, required this.sessionId});

  @override
  ConsumerState<PersonSessionScreen> createState() => _PersonSessionScreenState();
}

class _PersonSessionScreenState extends ConsumerState<PersonSessionScreen>
{
  WorkoutSession? _session;
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
      final session = await ref.read(apiProv).getPersonSession(widget.personId, widget.sessionId);
      if (mounted)
      {
        setState(()
        {
          _session = session;
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

  void _back()
  {
    if (context.canPop())
    {
      context.pop();
    }
    else
    {
      context.go('/app/people/${widget.personId}');
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final session = _session;
    if (session == null)
    {
      return _error != null ? ErrorRetry(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator());
    }

    final finished = session.finishedTs;
    final meta = [
      if (session.programName != null) session.programName!,
      DateFormat.yMMMd(aContext.locale.toLanguageTag()).add_Hm().format(session.startedTs),
      if (finished != null) formatSpan(finished.difference(session.startedTs)) else 'training.not_finished'.tr(),
      if (session.intensity != null) 'training.intensity_value'.tr(args: ['${session.intensity}']),
      if (session.kcal != null) 'training.kcal'.tr(args: [formatNumber(aContext, session.kcal!)]),
    ];

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
                Row(
                  children: [
                    IconButton(tooltip: 'common.back'.tr(), onPressed: _back, icon: const Icon(AppIcons.chevronLeft)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        session.dayName ?? 'training.free_workout'.tr(),
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 52),
                  child: Text(meta.join(' · '), style: TextStyle(color: context.palette.inkSecondary)),
                ),
                const SizedBox(height: 16),
                for (final exercise in session.exercises) ...[
                  _buildExercise(aContext, exercise),
                  const SizedBox(height: 12),
                ],
                if (session.note != null && session.note!.isNotEmpty)
                  Text(session.note!, style: TextStyle(color: context.palette.inkSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExercise(BuildContext aContext, SessionExercise aExercise)
  {
    final done = aExercise.sets.where((aSet) => aSet.isDone).toList();

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.palette.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(exerciseName(aExercise.exCode, aExercise.exName), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              done.isEmpty ? 'training.sets_done'.tr(args: ['0']) : describeSets(aContext, done),
              style: TextStyle(color: context.palette.inkSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
