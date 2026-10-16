import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_svc.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import 'exercise_picker.dart';
import 'training_format.dart';
import 'training_revision.dart';
import '../common/app_theme.dart';

const double _contentMaxWidth = 960;
const Duration _saveDelay = Duration(milliseconds: 1200);
const int _maxSets = 30;
const int _defaultIntensity = 6;

class WorkoutSessionScreen extends ConsumerStatefulWidget
{
  final String sessionId;

  const WorkoutSessionScreen({super.key, required this.sessionId});

  @override
  ConsumerState<WorkoutSessionScreen> createState() => _WorkoutSessionScreenState();
}

class _WorkoutSessionScreenState extends ConsumerState<WorkoutSessionScreen>
{
  final _noteCtrl = TextEditingController();
  WorkoutSession? _session;
  List<DictExDto> _catalog = const [];
  Object? _loadError;
  int _generation = 0;
  bool _isBusy = false;
  bool _isDirty = false;
  bool _isSaving = false;
  Timer? _saveTimer;
  Timer? _ticker;
  int _restLeft = 0;
  late final ApiSvc _api;

  @override
  void initState()
  {
    super.initState();
    _api = ref.read(apiProv);
    _load();
  }

  @override
  void dispose()
  {
    _saveTimer?.cancel();
    _ticker?.cancel();
    if (_isDirty)
    {
      unawaited(_persist());
    }
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    setState(() => _loadError = null);
    try
    {
      final session = await _api.getSession(widget.sessionId);
      final catalog = await _api.getExercises();
      if (mounted)
      {
        _apply(session);
        setState(() => _catalog = catalog);
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

  void _apply(WorkoutSession aSession)
  {
    setState(()
    {
      _session = aSession;
      _noteCtrl.text = aSession.note ?? '';
      _generation++;
      _isDirty = false;
    });
  }

  void _changed()
  {
    _isDirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_persist()));
    setState(() {});
  }

  Future<void> _persist() async
  {
    final session = _session;
    if (session == null || !_isDirty)
    {
      return;
    }
    _isDirty = false;
    if (mounted)
    {
      setState(() => _isSaving = true);
    }
    try
    {
      final note = _noteCtrl.text.trim();
      await _api.saveSession(session.id, note.isEmpty ? null : note, session.exercises);
    }
    catch (aError)
    {
      _isDirty = true;
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isSaving = false);
      }
    }
  }

  void _startRest(int aSeconds)
  {
    _ticker?.cancel();
    setState(() => _restLeft = aSeconds);
    _ticker = Timer.periodic(const Duration(seconds: 1), (aTimer)
    {
      if (!mounted || _restLeft <= 1)
      {
        aTimer.cancel();
        if (mounted)
        {
          setState(() => _restLeft = 0);
          HapticFeedback.heavyImpact();
        }
        return;
      }
      setState(() => _restLeft--);
    });
  }

  void _toggleDone(SessionExercise aExercise, SessionSet aSet, bool aIsDone)
  {
    aSet.isDone = aIsDone;
    final rest = aExercise.restSec;
    if (aIsDone && rest != null && rest > 0 && !(_session?.isFinished ?? true))
    {
      _startRest(rest);
    }
    _changed();
  }

  Future<void> _addExercise() async
  {
    final picked = await showExercisePicker(context, _catalog);
    final session = _session;
    if (picked == null || session == null)
    {
      return;
    }
    final isTimed = picked.exType == 'cardio' || picked.exType == 'flexibility';
    session.exercises.add(SessionExercise(
      exId: picked.id,
      exCode: picked.code,
      exName: picked.name,
      exType: picked.exType,
      sets: [SessionSet(durationSec: isTimed ? 600 : null)],
    ));
    _generation++;
    _changed();
  }

  Future<void> _finish() async
  {
    final intensity = await showDialog<int>(context: context, builder: (_) => const _IntensityDialog());
    final session = _session;
    if (intensity == null || session == null || !mounted)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      _saveTimer?.cancel();
      _isDirty = true;
      await _persist();
      final finished = await _api.finishSession(session.id, intensity);
      if (!mounted)
      {
        return;
      }
      _ticker?.cancel();
      _restLeft = 0;
      _apply(finished);
      notifyTrainingChanged(ref);
      showInfoSnack(
        context,
        finished.kcal == null
            ? 'training.finished_no_weight'.tr()
            : 'training.finished_kcal'.tr(args: [formatNumber(context, finished.kcal!)]),
      );
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

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(context, aTitle: 'training.delete_workout'.tr(), aMessage: 'training.delete_workout_confirm'.tr());
    if (!isConfirmed || !mounted)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      _saveTimer?.cancel();
      _isDirty = false;
      await _api.deleteSession(widget.sessionId);
      if (mounted)
      {
        notifyTrainingChanged(ref);
        _back();
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isBusy = false);
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
      context.go('/app/training');
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final session = _session;
    if (session == null)
    {
      return _loadError != null
          ? ErrorRetry(error: _loadError!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        ListView(
          padding: screenPadding(aContext).copyWith(bottom: 96),
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(aContext, session),
                    const SizedBox(height: 16),
                    for (var index = 0; index < session.exercises.length; index++) ...[
                      _buildExercise(aContext, session, index),
                      const SizedBox(height: 12),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _isBusy ? null : _addExercise,
                        icon: const Icon(AppIcons.plus, size: 18),
                        label: Text('training.add_exercise'.tr()),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _noteCtrl,
                      maxLines: 2,
                      inputFormatters: [LengthLimitingTextInputFormatter(500)],
                      onChanged: (_) => _changed(),
                      decoration: InputDecoration(labelText: 'training.note'.tr(), border: const OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!session.isFinished)
                          FilledButton.icon(
                            onPressed: _isBusy ? null : _finish,
                            icon: const Icon(AppIcons.checkCircle, size: 18),
                            label: Text('training.finish'.tr()),
                          ),
                        TextButton(
                          style: TextButton.styleFrom(foregroundColor: context.palette.danger),
                          onPressed: _isBusy ? null : _delete,
                          child: Text('training.delete_workout'.tr()),
                        ),
                      ],
                    ),
                    if (_isBusy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (_restLeft > 0)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Material(
              elevation: 4,
              color: context.palette.inkPrimary,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(AppIcons.clock, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'training.rest_left'.tr(args: [formatClock(_restLeft)]),
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: ()
                      {
                        _ticker?.cancel();
                        setState(() => _restLeft = 0);
                      },
                      child: Text('training.skip_rest'.tr(), style: const TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeader(BuildContext aContext, WorkoutSession aSession)
  {
    final locale = aContext.locale.toLanguageTag();
    final finished = aSession.finishedTs;
    final details = [
      DateFormat.yMMMd(locale).add_Hm().format(aSession.startedTs),
      if (finished != null) formatSpan(finished.difference(aSession.startedTs)),
      if (aSession.intensity != null) 'training.intensity_value'.tr(args: ['${aSession.intensity}']),
      if (aSession.kcal != null) 'training.kcal'.tr(args: [formatNumber(aContext, aSession.kcal!)]),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(tooltip: 'common.back'.tr(), onPressed: _back, icon: const Icon(AppIcons.chevronLeft)),
        const SizedBox(width: 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(aSession.dayName ?? 'training.free_workout'.tr(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              if (aSession.programName != null) Text(aSession.programName!, style: TextStyle(color: context.palette.inkSecondary)),
              const SizedBox(height: 4),
              Text(details.join(' · '), style: TextStyle(color: context.palette.inkSecondary)),
              const SizedBox(height: 4),
              Text(
                aSession.isFinished ? 'training.finished_label'.tr() : (_isSaving ? 'training.saving'.tr() : (_isDirty ? 'training.unsaved'.tr() : 'training.saved'.tr())),
                style: TextStyle(color: aSession.isFinished ? context.palette.positive : context.palette.inkMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildExercise(BuildContext aContext, WorkoutSession aSession, int aIndex)
  {
    final exercise = aSession.exercises[aIndex];
    final target = describeTarget(
      aContext,
      aSets: exercise.sets.length,
      aRepsMin: exercise.repsMin,
      aRepsMax: exercise.repsMax,
      aDurationSec: exercise.durationSec,
      aWeight: exercise.targetWeight,
      aRestSec: exercise.restSec,
    );
    final previousTs = exercise.previousTs;

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
            Row(
              children: [
                Expanded(
                  child: Text(
                    exerciseName(exercise.exCode, exercise.exName),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'training.progress'.tr(),
                  onPressed: () => context.push('/app/training/exercises/${exercise.exId}'),
                  icon: const Icon(AppIcons.trendingUp, size: 18),
                ),
                IconButton(
                  tooltip: 'training.remove_exercise'.tr(),
                  onPressed: ()
                  {
                    aSession.exercises.removeAt(aIndex);
                    _generation++;
                    _changed();
                  },
                  icon: const Icon(AppIcons.x, size: 18),
                ),
              ],
            ),
            Text(target, style: TextStyle(color: context.palette.inkSecondary)),
            if (exercise.advice != null && !aSession.isFinished) _AdviceLine(advice: exercise.advice!),
            if (exercise.previous.isNotEmpty && previousTs != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'training.previous'.tr(args: [
                    DateFormat.MMMd(aContext.locale.toLanguageTag()).format(previousTs),
                    describeSets(aContext, exercise.previous),
                  ]),
                  style: TextStyle(color: context.palette.inkMuted, fontSize: 13),
                ),
              ),
            const SizedBox(height: 8),
            for (var setIndex = 0; setIndex < exercise.sets.length; setIndex++) _buildSet(aContext, exercise, setIndex),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: exercise.sets.length >= _maxSets
                    ? null
                    : ()
                    {
                      exercise.sets.add(exercise.sets.isEmpty ? SessionSet() : exercise.sets.last.copy());
                      _generation++;
                      _changed();
                    },
                icon: const Icon(AppIcons.plus, size: 16),
                label: Text('training.add_set'.tr()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSet(BuildContext aContext, SessionExercise aExercise, int aSetIndex)
  {
    final set = aExercise.sets[aSetIndex];
    final keyPrefix = '$_generation-${aExercise.exId}-$aSetIndex';

    Widget field(String aKey, String aLabel, String aInitial, ValueChanged<String> aOnChanged, {bool aIsDecimal = false}) => SizedBox(
          width: 96,
          child: TextFormField(
            key: ValueKey('$keyPrefix-$aKey'),
            initialValue: aInitial,
            keyboardType: TextInputType.numberWithOptions(decimal: aIsDecimal),
            inputFormatters: [
              FilteringTextInputFormatter.allow(aIsDecimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]')),
              LengthLimitingTextInputFormatter(6),
            ],
            onChanged: (aValue)
            {
              aOnChanged(aValue.trim().replaceAll(',', '.'));
              _changed();
            },
            decoration: InputDecoration(labelText: aLabel, border: const OutlineInputBorder(), isDense: true),
          ),
        );

    String text(num? aValue) => aValue == null ? '' : (aValue == aValue.roundToDouble() ? aValue.toInt().toString() : aValue.toString());

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('${aSetIndex + 1}', style: TextStyle(color: context.palette.inkSecondary, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!aExercise.isTimed || set.weightKg != null)
                  field('w', 'training.weight'.tr(), text(set.weightKg), (aValue) => set.weightKg = double.tryParse(aValue), aIsDecimal: true),
                if (aExercise.isTimed)
                  field('d', 'training.duration_sec'.tr(), text(set.durationSec), (aValue) => set.durationSec = int.tryParse(aValue))
                else
                  field('r', 'training.reps'.tr(), text(set.reps), (aValue) => set.reps = int.tryParse(aValue)),
              ],
            ),
          ),
          Checkbox(
            value: set.isDone,
            semanticLabel: 'training.set_done'.tr(args: ['${aSetIndex + 1}']),
            onChanged: (aValue) => _toggleDone(aExercise, set, aValue ?? false),
          ),
          IconButton(
            tooltip: 'training.remove_set'.tr(),
            onPressed: ()
            {
              aExercise.sets.removeAt(aSetIndex);
              _generation++;
              _changed();
            },
            icon: Icon(AppIcons.x, size: 16, color: context.palette.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _IntensityDialog extends StatefulWidget
{
  const _IntensityDialog();

  @override
  State<_IntensityDialog> createState() => _IntensityDialogState();
}

class _IntensityDialogState extends State<_IntensityDialog>
{
  int _value = _defaultIntensity;

  String get _label => switch (_value)
  {
    <= 3 => 'training.intensity_light'.tr(),
    <= 6 => 'training.intensity_moderate'.tr(),
    <= 8 => 'training.intensity_hard'.tr(),
    _ => 'training.intensity_max'.tr(),
  };

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      scrollable: true,
      title: Text('training.finish'.tr()),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('training.intensity_question'.tr()),
            const SizedBox(height: 12),
            Text('$_value · $_label', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            Slider(
              value: _value.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              semanticFormatterCallback: (aValue) => '${aValue.round()} · $_label',
              onChanged: (aValue) => setState(() => _value = aValue.round()),
            ),
            Text('training.intensity_hint'.tr(), style: TextStyle(color: context.palette.inkMuted, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        FilledButton(onPressed: () => Navigator.of(aContext).pop(_value), child: Text('training.finish_action'.tr())),
      ],
    );
  }
}

class _AdviceLine extends StatelessWidget
{
  final ProgressionAdvice advice;

  const _AdviceLine({required this.advice});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final iconColor = advice.kind == ProgressionKind.deload ? palette.warning : aContext.colors.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(adviceIcon(advice.kind), size: 16, color: iconColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              adviceText(aContext, advice),
              style: TextStyle(color: palette.inkPrimary, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
