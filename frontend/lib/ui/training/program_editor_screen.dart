import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'exercise_picker.dart';
import 'training_format.dart';

const double _contentMaxWidth = 960;
const double _numberFieldWidth = 104;
const Color _borderColor = Color(0xFFE5E7EB);
const int _maxDays = 14;
const int _maxDayExercises = 30;
const int _maxRestDays = 14;

class _ExerciseDraft
{
  DictExDto? exercise;
  final setsCtrl = TextEditingController(text: '3');
  final repsMinCtrl = TextEditingController();
  final repsMaxCtrl = TextEditingController();
  final weightCtrl = TextEditingController();
  final durationCtrl = TextEditingController();
  final restCtrl = TextEditingController();
  final stepCtrl = TextEditingController();

  _ExerciseDraft();

  factory _ExerciseDraft.from(ProgramExercise aExercise, DictExDto? aDict)
  {
    String text(num? aValue) => aValue == null ? '' : (aValue == aValue.roundToDouble() ? aValue.toInt().toString() : aValue.toString());
    final draft = _ExerciseDraft()..exercise = aDict;
    draft.setsCtrl.text = '${aExercise.sets}';
    draft.repsMinCtrl.text = text(aExercise.repsMin);
    draft.repsMaxCtrl.text = text(aExercise.repsMax);
    draft.weightCtrl.text = text(aExercise.weightKg);
    draft.durationCtrl.text = text(aExercise.durationSec);
    draft.restCtrl.text = text(aExercise.restSec);
    draft.stepCtrl.text = text(aExercise.weightStep);
    return draft;
  }

  void dispose()
  {
    for (final ctrl in [setsCtrl, repsMinCtrl, repsMaxCtrl, weightCtrl, durationCtrl, restCtrl, stepCtrl])
    {
      ctrl.dispose();
    }
  }
}

class _DayDraft
{
  final String? id;
  final TextEditingController nameCtrl;
  int restDaysAfter;
  final Set<int> weekdays;
  final List<_ExerciseDraft> exercises;

  _DayDraft({this.id, required String aName, this.restDaysAfter = 1, Set<int>? aWeekdays, List<_ExerciseDraft>? aExercises})
      : nameCtrl = TextEditingController(text: aName),
        weekdays = aWeekdays ?? {},
        exercises = aExercises ?? [];

  void dispose()
  {
    nameCtrl.dispose();
    for (final exercise in exercises)
    {
      exercise.dispose();
    }
  }
}

class ProgramEditorScreen extends ConsumerStatefulWidget
{
  final String? programId;

  const ProgramEditorScreen({super.key, this.programId});

  @override
  ConsumerState<ProgramEditorScreen> createState() => _ProgramEditorScreenState();
}

class _ProgramEditorScreenState extends ConsumerState<ProgramEditorScreen>
{
  final _nameCtrl = TextEditingController();
  final List<_DayDraft> _days = [];
  List<DictExDto> _catalog = const [];
  ScheduleMode _mode = ScheduleMode.intervals;
  bool _isLoaded = false;
  bool _isBusy = false;
  bool _isActive = false;
  Object? _loadError;

  bool get _isEdit => widget.programId != null;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    for (final day in _days)
    {
      day.dispose();
    }
    super.dispose();
  }

  String _dayLetter(int aIndex) => String.fromCharCode('A'.codeUnitAt(0) + aIndex);

  Future<void> _load() async
  {
    setState(() => _loadError = null);
    try
    {
      final api = ref.read(apiProv);
      final catalog = await api.getExercises();
      final program = widget.programId == null ? null : await api.getProgram(widget.programId!);
      if (!mounted)
      {
        return;
      }
      final byId = {for (final exercise in catalog) exercise.id: exercise};
      setState(()
      {
        _catalog = catalog;
        if (program != null)
        {
          _nameCtrl.text = program.name;
          _mode = program.mode;
          _isActive = program.isActive;
          _days.addAll(program.days.map((aDay) => _DayDraft(
                id: aDay.id,
                aName: aDay.name,
                restDaysAfter: aDay.restDaysAfter,
                aWeekdays: aDay.weekdays.toSet(),
                aExercises: aDay.exercises.map((aExercise) => _ExerciseDraft.from(aExercise, byId[aExercise.exId])).toList(),
              )));
        }
        else
        {
          _days.add(_DayDraft(aName: '${'training.day'.tr()} ${_dayLetter(0)}'));
        }
        _isLoaded = true;
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
  }

  int? _int(TextEditingController aCtrl) => int.tryParse(aCtrl.text.trim());

  double? _decimal(TextEditingController aCtrl)
  {
    final text = aCtrl.text.trim().replaceAll(',', '.');
    return text.isEmpty ? null : double.tryParse(text);
  }

  String? _validate()
  {
    if (_nameCtrl.text.trim().isEmpty)
    {
      return 'training.err_name'.tr();
    }
    if (_days.isEmpty)
    {
      return 'training.err_days'.tr();
    }
    for (final day in _days)
    {
      if (day.nameCtrl.text.trim().isEmpty)
      {
        return 'training.err_day_name'.tr();
      }
      if (day.exercises.any((aExercise) => aExercise.exercise == null))
      {
        return 'training.err_exercise'.tr(args: [day.nameCtrl.text.trim()]);
      }
      final sets = day.exercises.map((aExercise) => _int(aExercise.setsCtrl));
      if (sets.any((aSets) => aSets == null || aSets < 1 || aSets > 20))
      {
        return 'training.err_sets'.tr(args: [day.nameCtrl.text.trim()]);
      }
    }
    if (_mode == ScheduleMode.weekdays)
    {
      final all = _days.expand((aDay) => aDay.weekdays).toList();
      if (all.isEmpty)
      {
        return 'training.err_weekdays_empty'.tr();
      }
      if (all.toSet().length != all.length)
      {
        return 'training.err_weekdays_overlap'.tr();
      }
    }
    return null;
  }

  Future<void> _save() async
  {
    final error = _validate();
    if (error != null)
    {
      showInfoSnack(context, error);
      return;
    }

    final days = _days
        .map((aDay) => ProgramDay(
              id: aDay.id,
              name: aDay.nameCtrl.text.trim(),
              restDaysAfter: aDay.restDaysAfter,
              weekdays: (aDay.weekdays.toList()..sort()),
              exercises: aDay.exercises
                  .map((aExercise) => ProgramExercise(
                        exId: aExercise.exercise!.id,
                        sets: _int(aExercise.setsCtrl)!,
                        repsMin: _int(aExercise.repsMinCtrl),
                        repsMax: _int(aExercise.repsMaxCtrl),
                        durationSec: _int(aExercise.durationCtrl),
                        weightKg: _decimal(aExercise.weightCtrl),
                        restSec: _int(aExercise.restCtrl),
                        weightStep: _decimal(aExercise.stepCtrl),
                      ))
                  .toList(),
            ))
        .toList();

    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).saveProgram(widget.programId, _nameCtrl.text.trim(), _mode, days);
      if (mounted)
      {
        showInfoSnack(context, 'training.program_saved'.tr());
        context.pop();
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

  Future<void> _delete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'training.delete_program'.tr(),
      aMessage: 'training.delete_program_confirm'.tr(args: [_nameCtrl.text.trim()]),
    );
    if (!isConfirmed || !mounted)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).deleteProgram(widget.programId!);
      if (mounted)
      {
        context.pop();
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

  Future<void> _pickExercise(_ExerciseDraft aDraft) async
  {
    final picked = await showExercisePicker(context, _catalog);
    if (picked != null)
    {
      setState(()
      {
        aDraft.exercise = picked;
        if (picked.exType == 'cardio' || picked.exType == 'flexibility' || picked.code == 'plank')
        {
          aDraft.repsMinCtrl.clear();
          aDraft.repsMaxCtrl.clear();
        }
      });
    }
  }

  void _addDay()
  {
    setState(() => _days.add(_DayDraft(aName: '${'training.day'.tr()} ${_dayLetter(_days.length)}')));
  }

  void _moveDay(int aIndex, int aDelta)
  {
    final target = aIndex + aDelta;
    if (target < 0 || target >= _days.length)
    {
      return;
    }
    setState(()
    {
      final day = _days.removeAt(aIndex);
      _days.insert(target, day);
    });
  }

  void _removeDay(int aIndex)
  {
    setState(() => _days.removeAt(aIndex).dispose());
  }

  void _moveExercise(_DayDraft aDay, int aIndex, int aDelta)
  {
    final target = aIndex + aDelta;
    if (target < 0 || target >= aDay.exercises.length)
    {
      return;
    }
    setState(()
    {
      final exercise = aDay.exercises.removeAt(aIndex);
      aDay.exercises.insert(target, exercise);
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    if (!_isLoaded)
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
                  title: _isEdit ? 'training.edit_program'.tr() : 'training.new_program'.tr(),
                  actions: [
                    if (_isEdit)
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
                        onPressed: _isBusy ? null : _delete,
                        child: Text('training.delete_program'.tr()),
                      ),
                    FilledButton.icon(
                      onPressed: _isBusy ? null : _save,
                      icon: const Icon(AppIcons.save, size: 18),
                      label: Text('common.save'.tr()),
                    ),
                  ],
                ),
                if (_isActive) ...[
                  const SizedBox(height: 4),
                  Text('training.active_hint'.tr(), style: const TextStyle(color: inkSecondary)),
                ],
                const SizedBox(height: 20),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Semantics(
                    container: true,
                    child: TextField(
                      controller: _nameCtrl,
                      inputFormatters: [LengthLimitingTextInputFormatter(100)],
                      decoration: InputDecoration(labelText: 'training.program_name'.tr(), border: const OutlineInputBorder()),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text('training.schedule'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<ScheduleMode>(
                    segments: [
                      for (final mode in ScheduleMode.values)
                        ButtonSegment(value: mode, label: Text('training.mode_${mode.name}'.tr())),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (aSelected) => setState(() => _mode = aSelected.first),
                  ),
                ),
                const SizedBox(height: 6),
                Text('training.mode_${_mode.name}_hint'.tr(), style: const TextStyle(color: inkSecondary, fontSize: 13)),
                const SizedBox(height: 20),
                for (var index = 0; index < _days.length; index++) ...[
                  _buildDay(aContext, index),
                  const SizedBox(height: 12),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _days.length >= _maxDays ? null : _addDay,
                    icon: const Icon(AppIcons.plus, size: 18),
                    label: Text('training.add_day'.tr()),
                  ),
                ),
                if (_isBusy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDay(BuildContext aContext, int aIndex)
  {
    final day = _days[aIndex];

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: _borderColor)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: day.nameCtrl,
                    inputFormatters: [LengthLimitingTextInputFormatter(100)],
                    decoration: InputDecoration(labelText: 'training.day_name'.tr(), border: const OutlineInputBorder(), isDense: true),
                  ),
                ),
                IconButton(
                  tooltip: 'training.move_up'.tr(),
                  onPressed: aIndex == 0 ? null : () => _moveDay(aIndex, -1),
                  icon: const Icon(AppIcons.chevronUp, size: 18),
                ),
                IconButton(
                  tooltip: 'training.move_down'.tr(),
                  onPressed: aIndex == _days.length - 1 ? null : () => _moveDay(aIndex, 1),
                  icon: const Icon(AppIcons.chevronDown, size: 18),
                ),
                IconButton(
                  tooltip: 'training.remove_day'.tr(),
                  onPressed: _days.length == 1 ? null : () => _removeDay(aIndex),
                  icon: const Icon(AppIcons.trash2, size: 18, color: Colors.red),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_mode == ScheduleMode.intervals)
              Row(
                children: [
                  Expanded(child: Text('training.rest_after'.tr(), style: const TextStyle(color: inkSecondary))),
                  IconButton(
                    tooltip: 'training.less'.tr(),
                    onPressed: day.restDaysAfter <= 0 ? null : () => setState(() => day.restDaysAfter--),
                    icon: const Icon(AppIcons.chevronDown, size: 18),
                  ),
                  Text('training.rest_days'.plural(day.restDaysAfter), style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    tooltip: 'training.more'.tr(),
                    onPressed: day.restDaysAfter >= _maxRestDays ? null : () => setState(() => day.restDaysAfter++),
                    icon: const Icon(AppIcons.chevronUp, size: 18),
                  ),
                ],
              ),
            if (_mode == ScheduleMode.weekdays)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var weekday = 1; weekday <= 7; weekday++)
                    FilterChip(
                      label: Text(weekdayShort(aContext, weekday)),
                      selected: day.weekdays.contains(weekday),
                      onSelected: (aIsSelected) => setState(() => aIsSelected ? day.weekdays.add(weekday) : day.weekdays.remove(weekday)),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            for (var exIndex = 0; exIndex < day.exercises.length; exIndex++) _buildExercise(aContext, day, exIndex),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: day.exercises.length >= _maxDayExercises ? null : () async
                {
                  final draft = _ExerciseDraft();
                  setState(() => day.exercises.add(draft));
                  await _pickExercise(draft);
                },
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('training.add_exercise'.tr()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExercise(BuildContext aContext, _DayDraft aDay, int aIndex)
  {
    final draft = aDay.exercises[aIndex];
    final exercise = draft.exercise;

    Widget field(TextEditingController aCtrl, String aLabel, {bool aIsDecimal = false}) => SizedBox(
          width: _numberFieldWidth,
          child: TextField(
            controller: aCtrl,
            keyboardType: TextInputType.numberWithOptions(decimal: aIsDecimal),
            inputFormatters: [
              FilteringTextInputFormatter.allow(aIsDecimal ? RegExp(r'[0-9.,]') : RegExp(r'[0-9]')),
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: InputDecoration(labelText: aLabel, border: const OutlineInputBorder(), isDense: true),
          ),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: _borderColor))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _pickExercise(draft),
                    icon: const Icon(AppIcons.dumbbell, size: 16),
                    label: Text(exercise == null ? 'training.pick_exercise'.tr() : exerciseDisplayName(exercise), overflow: TextOverflow.ellipsis),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'training.move_up'.tr(),
                onPressed: aIndex == 0 ? null : () => _moveExercise(aDay, aIndex, -1),
                icon: const Icon(AppIcons.chevronUp, size: 18),
              ),
              IconButton(
                tooltip: 'training.move_down'.tr(),
                onPressed: aIndex == aDay.exercises.length - 1 ? null : () => _moveExercise(aDay, aIndex, 1),
                icon: const Icon(AppIcons.chevronDown, size: 18),
              ),
              IconButton(
                tooltip: 'training.remove_exercise'.tr(),
                onPressed: () => setState(() => aDay.exercises.removeAt(aIndex).dispose()),
                icon: const Icon(AppIcons.x, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              field(draft.setsCtrl, 'training.sets'.tr()),
              field(draft.repsMinCtrl, 'training.reps_min'.tr()),
              field(draft.repsMaxCtrl, 'training.reps_max'.tr()),
              field(draft.weightCtrl, 'training.weight'.tr(), aIsDecimal: true),
              field(draft.durationCtrl, 'training.duration_sec'.tr()),
              field(draft.restCtrl, 'training.rest_sec'.tr()),
              field(draft.stepCtrl, 'training.weight_step'.tr(), aIsDecimal: true),
            ],
          ),
        ],
      ),
    );
  }
}
