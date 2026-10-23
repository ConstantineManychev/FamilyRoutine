import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../nutrition/nutrition_diary_screen.dart' show addFoodPath;
import '../nutrition/nutrition_format.dart';
import '../planner/planner_common.dart' show currentMinute, notifyPlannerChanged, occurrenceTimeLabel, pickMoveStart;
import '../training/training_format.dart' show describeSets;
import '../study/study_block_panel.dart';
import '../work/work_block_panel.dart';
import 'routine_style.dart';

const int _maxNoteLen = 200;
const double _panelRadius = 12;

class MarkRoute
{
  final String path;
  final bool isReturning;

  const MarkRoute(this.path, {this.isReturning = false});
}

Future<void> openMarkSheet(BuildContext aContext, String aMarkId) async
{
  var route = await _showMarkSheet(aContext, aMarkId);
  while (route != null)
  {
    if (!aContext.mounted)
    {
      return;
    }
    await aContext.push(route.path);
    if (!route.isReturning || !aContext.mounted)
    {
      return;
    }
    route = await _showMarkSheet(aContext, aMarkId);
  }
}

Future<MarkRoute?> _showMarkSheet(BuildContext aContext, String aMarkId)
{
  return showModalBottomSheet<MarkRoute>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => MarkSheet(markId: aMarkId),
  );
}

DateTime _endAfter(DateTime aStart, TimeOfDay aTime)
{
  final sameDay = DateTime(aStart.year, aStart.month, aStart.day, aTime.hour, aTime.minute);
  return sameDay.isAfter(aStart) ? sameDay : DateTime(aStart.year, aStart.month, aStart.day + 1, aTime.hour, aTime.minute);
}

class MarkSheet extends ConsumerStatefulWidget
{
  final String markId;

  const MarkSheet({super.key, required this.markId});

  @override
  ConsumerState<MarkSheet> createState() => _MarkSheetState();
}

class _MarkSheetState extends ConsumerState<MarkSheet>
{
  final _noteCtrl = TextEditingController();

  MarkDetails? _details;
  Object? _error;
  RoutineStatus _status = RoutineStatus.other;
  DateTime _start = DateTime.now();
  DateTime? _end;
  bool _isBusy = false;

  String? get _personId
  {
    final details = _details;
    return details == null || details.isMine ? null : details.ownerId;
  }

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    try
    {
      final details = await ref.read(apiProv).getMarkDetails(widget.markId);
      if (mounted)
      {
        setState(()
        {
          _details = details;
          _status = details.mark.status;
          _start = details.mark.startTs;
          _end = details.mark.endTs;
          _noteCtrl.text = details.mark.note ?? '';
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

  bool _isTimeChanged(StatusMarkDto aMark) => _start != aMark.startTs || _end != aMark.endTs;

  bool _isChanged(StatusMarkDto aMark) =>
      _status != aMark.status || _noteCtrl.text.trim() != (aMark.note ?? '') || _isTimeChanged(aMark);

  Future<void> _pickDate() async
  {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: dayOnly(_start),
      firstDate: dayOnly(now.subtract(const Duration(days: maxMarkPastDays))),
      lastDate: dayOnly(now.add(const Duration(days: 1))),
    );
    if (picked == null || !mounted)
    {
      return;
    }
    final shift = DateTime(picked.year, picked.month, picked.day).difference(dayOnly(_start)).inDays;
    if (shift == 0)
    {
      return;
    }
    setState(()
    {
      _start = DateTime(_start.year, _start.month, _start.day + shift, _start.hour, _start.minute);
      final end = _end;
      if (end != null)
      {
        _end = DateTime(end.year, end.month, end.day + shift, end.hour, end.minute);
      }
    });
  }

  Future<void> _pickStart() async
  {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_start));
    if (picked == null || !mounted)
    {
      return;
    }
    setState(()
    {
      _start = DateTime(_start.year, _start.month, _start.day, picked.hour, picked.minute);
      final end = _end;
      if (end != null && !end.isAfter(_start))
      {
        _end = _endAfter(_start, TimeOfDay.fromDateTime(end));
      }
    });
  }

  Future<void> _pickEnd() async
  {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_end ?? DateTime.now()));
    if (picked != null && mounted)
    {
      setState(() => _end = _endAfter(_start, picked));
    }
  }

  Future<void> _save(StatusMarkDto aMark) async
  {
    setState(() => _isBusy = true);
    try
    {
      final isTimeChanged = _isTimeChanged(aMark);
      await ref.read(apiProv).updateMark(
            aMark.id,
            _status,
            _noteCtrl.text,
            aStartTs: isTimeChanged ? _start : null,
            aEndTs: isTimeChanged ? _end : null,
            aIsOpenEnd: isTimeChanged && _end == null,
          );
      if (aMark.status == RoutineStatus.meal && _status != RoutineStatus.meal)
      {
        notifyNutritionChanged(ref);
      }
      else
      {
        ref.read(routineRevisionProv.notifier).state++;
      }
      if (mounted)
      {
        Navigator.of(context).pop();
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

  Future<void> _delete(StatusMarkDto aMark) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'routine.delete_mark'.tr(),
      aMessage: [
        'routine.delete_mark_confirm'.tr(args: [aMark.status.label, formatSpan(context, aMark)]),
        if ((_details?.meals?.entries ?? const []).isNotEmpty) 'routine.delete_meal_hint'.tr(),
      ].join('\n\n'),
    );
    if (!isConfirmed || !mounted)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).deleteMark(aMark.id);
      ref.read(routineRevisionProv.notifier).state++;
      if (mounted)
      {
        Navigator.of(context).pop();
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

  Future<void> _copyYesterday(StatusMarkDto aMark) async
  {
    setState(() => _isBusy = true);
    try
    {
      final api = ref.read(apiProv);
      final result = await api.copyMealFromYesterday(aMark.id, dayOnly(aMark.startTs), aPersonId: _personId);
      final details = await api.getMarkDetails(aMark.id);
      notifyNutritionChanged(ref);
      if (mounted)
      {
        setState(() => _details = details);
        showInfoSnack(
          context,
          result.sourceStartTs == null ? 'nutrition.copy_none'.tr() : 'nutrition.copied'.plural(result.copied),
        );
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

  Future<void> _linkEntries(StatusMarkDto aMark) async
  {
    final api = ref.read(apiProv);
    final List<MealEntry> entries;
    final Map<String, String> labels;
    try
    {
      final day = await api.getNutritionDay(dayOnly(aMark.startTs), aPersonId: _personId);
      if (!mounted)
      {
        return;
      }
      entries = [for (final meal in day.meals) ...meal.entries, ...day.unlinked];
      labels = {
        for (final meal in day.meals)
          for (final entry in meal.entries) entry.id: mealTitle(context, meal),
        for (final entry in day.unlinked) entry.id: 'nutrition.unlinked'.tr(),
      };
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
      return;
    }
    if (!mounted)
    {
      return;
    }

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (_) => _LinkEntriesDialog(markId: aMark.id, entries: entries, labels: labels),
    );
    if (selected == null || !mounted)
    {
      return;
    }

    setState(() => _isBusy = true);
    try
    {
      final details = await api.linkMarkMeals(aMark.id, selected);
      notifyNutritionChanged(ref);
      if (mounted)
      {
        setState(() => _details = details);
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

  Future<void> _refreshAfterPlan() async
  {
    notifyPlannerChanged(ref);
    notifyNutritionChanged(ref);
    try
    {
      final details = await ref.read(apiProv).getMarkDetails(widget.markId);
      if (mounted)
      {
        setState(()
        {
          _details = details;
          _status = details.mark.status;
          _start = details.mark.startTs;
          _end = details.mark.endTs;
          _noteCtrl.text = details.mark.note ?? '';
        });
      }
    }
    catch (_)
    {
      if (mounted)
      {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> _savePlan(Occurrence aPlan, PlanState aState, {DateTime? aMovedStart}) async
  {
    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).saveOccurrence(aPlan.eventId, aPlan.occDate, aState, aMovedStart: aMovedStart);
      await _refreshAfterPlan();
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

  Future<void> _movePlan(Occurrence aPlan) async
  {
    final start = await pickMoveStart(context, aPlan);
    if (start != null && mounted)
    {
      await _savePlan(aPlan, aPlan.state, aMovedStart: start);
    }
  }

  Future<void> _startPlanTraining(Occurrence aPlan) async
  {
    final sessionId = aPlan.sessionId;
    if (aPlan.isSessionActive && sessionId != null)
    {
      _leaveTo('/app/training/sessions/$sessionId', aIsReturning: false);
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      final session = await ref.read(apiProv).startOccurrence(aPlan.eventId, aPlan.occDate);
      notifyPlannerChanged(ref);
      if (mounted)
      {
        _leaveTo('/app/training/sessions/${session.id}', aIsReturning: false);
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

  void _leaveTo(String aPath, {bool aIsReturning = true})
  {
    Navigator.of(context).pop(MarkRoute(aPath, isReturning: aIsReturning));
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final media = MediaQuery.of(aContext);
    final details = _details;
    final Widget content;
    if (details == null)
    {
      content = Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: _error != null
            ? ErrorRetry(error: _error!, onRetry: _load)
            : const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
      );
    }
    else
    {
      content = _buildContent(aContext, details, media);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: (media.size.height - media.viewInsets.bottom) * 0.9),
        child: content,
      ),
    );
  }

  Widget _buildContent(BuildContext aContext, MarkDetails aDetails, MediaQueryData aMedia)
  {
    final mark = aDetails.mark;
    final palette = aContext.palette;
    final linkedCount = aDetails.meals?.entries.length ?? 0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _MarkHeader(details: aDetails),
                if (aDetails.plan != null && aDetails.canEdit) _buildPlan(aContext, aDetails, aDetails.plan!),
                _buildPanel(aContext, aDetails),
                if (aDetails.canEdit && !aDetails.isPlanned) ...[
                  const SizedBox(height: 20),
                  Text('routine.edit_mark'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<RoutineStatus>(
                    key: ValueKey('mark.type.${mark.id}.${mark.status.name}'),
                    initialValue: _status,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: 'routine.event_kind'.tr(), border: const OutlineInputBorder(), isDense: true),
                    items: [
                      for (final status in RoutineStatus.values)
                        DropdownMenuItem(
                          key: ValueKey('mark.type.${status.name}'),
                          value: status,
                          child: Row(
                            children: [
                              Icon(status.icon, size: 18, color: status.colorOf(aContext)),
                              const SizedBox(width: 10),
                              Flexible(child: Text(status.label, overflow: TextOverflow.ellipsis)),
                            ],
                          ),
                        ),
                    ],
                    onChanged: _isBusy ? null : (aStatus) => setState(() => _status = aStatus ?? _status),
                  ),
                  if (mark.status == RoutineStatus.meal && _status != RoutineStatus.meal && linkedCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('routine.unlink_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.warning)),
                    ),
                  const SizedBox(height: 16),
                  _buildTimes(aContext),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _noteCtrl,
                    onChanged: (_) => setState(() {}),
                    inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLen)],
                    decoration: InputDecoration(labelText: 'routine.note'.tr(), border: const OutlineInputBorder(), isDense: true),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (aDetails.canEdit && !aDetails.isPlanned)
          Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 20, 12 + aMedia.padding.bottom),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('mark.delete'),
                  tooltip: 'common.delete'.tr(),
                  color: palette.danger,
                  onPressed: _isBusy ? null : () => _delete(mark),
                  icon: const Icon(AppIcons.trash2),
                ),
                const Spacer(),
                TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
                const SizedBox(width: 8),
                ElevatedButton(
                  key: const ValueKey('mark.save'),
                  onPressed: _isBusy || !_isChanged(mark) ? null : () => _save(mark),
                  child: Text('common.save'.tr()),
                ),
              ],
            ),
          )
        else
          SizedBox(height: 12 + aMedia.padding.bottom),
      ],
    );
  }

  Widget _buildTimes(BuildContext aContext)
  {
    final palette = aContext.palette;
    final end = _end;
    final isNextDay = end != null && dayOnly(end) != dayOnly(_start);
    final endLabel = end == null ? '—' : '${formatClock(aContext, end)}${isNextDay ? ' +1' : ''}';

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('mark.date'),
          onPressed: _isBusy ? null : _pickDate,
          icon: const Icon(AppIcons.calendar, size: 16),
          label: Text(DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(_start)),
        ),
        OutlinedButton.icon(
          key: const ValueKey('mark.start'),
          onPressed: _isBusy ? null : _pickStart,
          icon: const Icon(AppIcons.clock, size: 16),
          label: Text('routine.start_at'.tr(args: [formatClock(aContext, _start)])),
        ),
        Text('—', style: TextStyle(color: palette.inkMuted)),
        OutlinedButton.icon(
          key: const ValueKey('mark.end'),
          onPressed: _isBusy ? null : _pickEnd,
          icon: const Icon(AppIcons.clock, size: 16),
          label: Text('routine.end_at'.tr(args: [endLabel])),
        ),
        ChoiceChip(
          key: const ValueKey('mark.open_end'),
          showCheckmark: false,
          label: Text('routine.open_end'.tr()),
          selected: end == null,
          onSelected: _isBusy ? null : (_) => setState(() => _end = null),
        ),
      ],
    );
  }

  Widget _buildPlan(BuildContext aContext, MarkDetails aDetails, Occurrence aPlan)
  {
    final palette = aContext.palette;
    final isToday = DateUtils.isSameDay(aPlan.startTs, DateTime.now());
    final isOpen = !aPlan.isDone && !aPlan.isSkipped;
    final stateKey = aPlan.isDone ? 'routine.plan_done' : (aPlan.isSkipped ? 'routine.plan_skipped' : 'routine.plan_waiting');
    final canStartTraining = aPlan.isTraining && isOpen && (isToday || aPlan.isSessionActive);
    final hintKey = switch (aDetails.mark.status)
    {
      _ when !aDetails.isPlanned => null,
      RoutineStatus.meal => 'routine.plan_meal_hint',
      RoutineStatus.gym when aPlan.isTraining => 'routine.plan_workout_hint',
      _ => 'routine.plan_block_hint',
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        key: const ValueKey('mark.plan'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(_panelRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(AppIcons.calendarClock, size: 18, color: palette.inkSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${'routine.plan'.tr()}: ${aPlan.title}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(stateKey.tr(), key: const ValueKey('mark.plan.state'), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              [
                '${DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(aPlan.startTs)} · ${occurrenceTimeLabel(aContext, aPlan)}',
                if (aPlan.isTraining) aPlan.dayName ?? 'planner.training_next_day'.tr(),
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: palette.inkSecondary),
            ),
            if (hintKey != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(hintKey.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isOpen)
                  FilledButton.icon(
                    key: const ValueKey('mark.plan.done'),
                    onPressed: _isBusy ? null : () => _savePlan(aPlan, PlanState.done),
                    icon: const Icon(AppIcons.checkCircle, size: 16),
                    label: Text('planner.done'.tr()),
                  )
                else
                  OutlinedButton.icon(
                    key: const ValueKey('mark.plan.undo'),
                    onPressed: _isBusy ? null : () => _savePlan(aPlan, PlanState.planned),
                    icon: const Icon(AppIcons.history, size: 16),
                    label: Text(aPlan.isDone ? 'planner.undo_done'.tr() : 'planner.unskip'.tr()),
                  ),
                if (canStartTraining)
                  FilledButton.tonalIcon(
                    key: const ValueKey('mark.plan.training'),
                    onPressed: _isBusy ? null : () => _startPlanTraining(aPlan),
                    icon: const Icon(AppIcons.dumbbell, size: 16),
                    label: Text(aPlan.isSessionActive ? 'planner.continue_training'.tr() : 'planner.start_training'.tr()),
                  ),
                if (isOpen && !aPlan.isTraining && isToday)
                  OutlinedButton.icon(
                    key: const ValueKey('mark.plan.now'),
                    onPressed: _isBusy ? null : () => _savePlan(aPlan, PlanState.done, aMovedStart: currentMinute()),
                    icon: const Icon(AppIcons.zap, size: 16),
                    label: Text('routine.plan_now'.tr()),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('mark.plan.move'),
                  onPressed: _isBusy ? null : () => _movePlan(aPlan),
                  icon: const Icon(AppIcons.calendarClock, size: 16),
                  label: Text('planner.move'.tr()),
                ),
                if (isOpen)
                  TextButton.icon(
                    key: const ValueKey('mark.plan.skip'),
                    onPressed: _isBusy ? null : () => _savePlan(aPlan, PlanState.skipped),
                    icon: const Icon(AppIcons.x, size: 16),
                    label: Text('planner.skip'.tr()),
                  ),
                TextButton.icon(
                  key: const ValueKey('mark.plan.edit'),
                  onPressed: _isBusy ? null : () => _leaveTo('/app/planner/events/${aPlan.eventId}'),
                  icon: const Icon(AppIcons.edit, size: 16),
                  label: Text('planner.edit_series'.tr()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext aContext, MarkDetails aDetails)
  {
    final status = aDetails.mark.status;
    if (aDetails.isDetailsHidden)
    {
      final key = switch (status)
      {
        RoutineStatus.gym => 'routine.hidden_workout',
        RoutineStatus.meal => 'routine.hidden_meals',
        _ => 'routine.hidden_private',
      };
      return _Panel(child: _PanelNote(icon: AppIcons.lock, text: key.tr()));
    }

    return switch (status)
    {
      RoutineStatus.gym => _Panel(child: _buildWorkout(aContext, aDetails)),
      RoutineStatus.meal => _Panel(child: _buildMeals(aContext, aDetails)),
      RoutineStatus.work when aDetails.work != null => _Panel(
          child: WorkBlockPanel(markId: aDetails.mark.id, work: aDetails.work!, onOpenAll: (aPath) => _leaveTo(aPath)),
        ),
      RoutineStatus.work => _Panel(child: _PanelNote(icon: AppIcons.listChecks, text: 'routine.work_placeholder'.tr())),
      RoutineStatus.school when aDetails.study != null => _Panel(
          child: StudyBlockPanel(
            markId: aDetails.mark.id,
            startTs: aDetails.mark.startTs,
            endTs: aDetails.mark.endTs,
            study: aDetails.study!,
            onOpenAll: (aPath) => _leaveTo(aPath),
          ),
        ),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _buildWorkout(BuildContext aContext, MarkDetails aDetails)
  {
    final session = aDetails.workout;
    final plan = aDetails.plan;
    if (session == null && aDetails.isPlanned && plan != null && plan.isTraining)
    {
      return _PanelNote(
        icon: AppIcons.dumbbell,
        text: 'routine.plan_workout'.tr(args: [plan.title, plan.dayName ?? 'planner.training_next_day'.tr()]),
      );
    }
    if (session == null)
    {
      return _PanelNote(
        icon: AppIcons.dumbbell,
        text: aDetails.canEdit ? 'routine.no_workout_mine'.tr() : 'routine.no_workout'.tr(),
      );
    }

    final palette = aContext.palette;
    final finished = session.finishedTs;
    final meta = [
      if (session.programName != null) session.programName!,
      finished == null
          ? 'training.not_finished'.tr()
          : formatDuration(finished.difference(session.startedTs)),
    ];
    final path = aDetails.canEdit
        ? '/app/training/sessions/${session.id}'
        : '/app/people/${aDetails.ownerId}/sessions/${session.id}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(AppIcons.dumbbell, size: 18, color: palette.inkSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                session.dayName ?? 'training.free_workout'.tr(),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(meta.join(' · '), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
        const SizedBox(height: 8),
        if (session.exercises.isEmpty)
          Text('routine.no_exercises'.tr(), style: TextStyle(color: palette.inkMuted))
        else
          for (final exercise in session.exercises)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(exercise.exName)),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      _doneSets(aContext, exercise),
                      textAlign: TextAlign.end,
                      style: TextStyle(color: palette.inkSecondary),
                    ),
                  ),
                ],
              ),
            ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('mark.open_workout'),
            onPressed: () => _leaveTo(path),
            icon: const Icon(AppIcons.chevronRight, size: 16),
            label: Text('routine.open_workout'.tr()),
          ),
        ),
      ],
    );
  }

  String _doneSets(BuildContext aContext, SessionExercise aExercise)
  {
    final done = aExercise.sets.where((aSet) => aSet.isDone).toList();
    return done.isEmpty ? '—' : describeSets(aContext, done);
  }

  Widget _buildMeals(BuildContext aContext, MarkDetails aDetails)
  {
    final palette = aContext.palette;
    final meals = aDetails.meals ?? const MarkMeals();
    final mark = aDetails.mark;
    final dayNorm = meals.dayNorm;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(AppIcons.utensils, size: 18, color: palette.inkSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                formatKcal(aContext, meals.total.kcal),
                key: const ValueKey('mark.meals_total'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(macrosLine(aContext, meals.total), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
        if (dayNorm != null && dayNorm.kcal > 0)
          Text(
            'routine.norm_share'.tr(args: [
              formatAmount(aContext, meals.total.kcal / dayNorm.kcal * 100, aDigits: 0),
              formatAmount(aContext, dayNorm.kcal, aDigits: 0),
            ]),
            key: const ValueKey('mark.norm_share'),
            style: TextStyle(fontSize: 12, color: palette.inkMuted),
          ),
        const SizedBox(height: 8),
        if (meals.entries.isEmpty)
          Text(
            switch (aDetails)
            {
              MarkDetails(isPlanned: true) => 'routine.no_meals_plan'.tr(),
              MarkDetails(canEdit: true) => 'routine.no_meals_mine'.tr(),
              _ => 'routine.no_meals'.tr(),
            },
            style: TextStyle(color: palette.inkMuted),
          )
        else
          for (final entry in meals.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entryTitle(entry)),
                        if (entry.grams != null)
                          Text(entryAmount(aContext, entry), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(formatKcal(aContext, entry.total.kcal), style: TextStyle(color: palette.inkSecondary)),
                ],
              ),
            ),
        if (aDetails.canEdit)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  key: const ValueKey('mark.copy_yesterday'),
                  onPressed: _isBusy ? null : () => _copyYesterday(mark),
                  icon: const Icon(AppIcons.history, size: 16),
                  label: Text('nutrition.copy_meal'.tr()),
                ),
                if (!aDetails.isPlanned)
                  TextButton.icon(
                    key: const ValueKey('mark.link_meals'),
                    onPressed: _isBusy ? null : () => _linkEntries(mark),
                    icon: const Icon(AppIcons.link, size: 16),
                    label: Text('routine.link_meals'.tr()),
                  ),
                FilledButton.tonalIcon(
                  key: const ValueKey('mark.add_food'),
                  onPressed: _isBusy
                      ? null
                      : () => _leaveTo(addFoodPath(dayOnly(mark.startTs), aMarkId: mark.id, aPersonId: _personId)),
                  icon: const Icon(AppIcons.plus, size: 16),
                  label: Text('routine.add_food'.tr()),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MarkHeader extends StatelessWidget
{
  final MarkDetails details;

  const _MarkHeader({required this.details});

  @override
  Widget build(BuildContext aContext)
  {
    final mark = details.mark;
    final palette = aContext.palette;
    final color = mark.status.colorOf(aContext);
    final end = mark.endTs ?? DateTime.now();
    final duration = end.isAfter(mark.startTs) ? end.difference(mark.startTs) : Duration.zero;
    final subtitle = [
      if (!details.isMine && details.ownerName.isNotEmpty) details.ownerName,
      formatSpan(aContext, mark),
      formatDuration(duration),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Icon(mark.status.icon, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(mark.status.label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(color: palette.inkSecondary)),
                if (mark.note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(mark.note!, style: TextStyle(color: palette.inkPrimary)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget
{
  final Widget child;

  const _Panel({required this.child});

  @override
  Widget build(BuildContext aContext)
  {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: aContext.palette.surfaceMuted,
        borderRadius: BorderRadius.circular(_panelRadius),
      ),
      child: child,
    );
  }
}

class _PanelNote extends StatelessWidget
{
  final IconData icon;
  final String text;

  const _PanelNote({required this.icon, required this.text});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: palette.inkMuted),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: palette.inkSecondary))),
      ],
    );
  }
}

class _LinkEntriesDialog extends StatefulWidget
{
  final String markId;
  final List<MealEntry> entries;
  final Map<String, String> labels;

  const _LinkEntriesDialog({required this.markId, required this.entries, required this.labels});

  @override
  State<_LinkEntriesDialog> createState() => _LinkEntriesDialogState();
}

class _LinkEntriesDialogState extends State<_LinkEntriesDialog>
{
  late final Set<String> _selected = {
    for (final entry in widget.entries)
      if (entry.statusMarkId == widget.markId) entry.id,
  };

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;

    return AlertDialog(
      title: Text('routine.link_meals'.tr()),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 420,
        child: widget.entries.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('routine.no_day_entries'.tr(), style: TextStyle(color: palette.inkMuted)),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in widget.entries)
                    CheckboxListTile(
                      value: _selected.contains(entry.id),
                      onChanged: (aValue) => setState(()
                      {
                        if (aValue ?? false)
                        {
                          _selected.add(entry.id);
                        }
                        else
                        {
                          _selected.remove(entry.id);
                        }
                      }),
                      title: Text(entryTitle(entry), maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          if (widget.labels[entry.id] != null) widget.labels[entry.id]!,
                          formatKcal(aContext, entry.total.kcal),
                        ].join(' · '),
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: widget.entries.isEmpty ? null : () => Navigator.of(aContext).pop(_selected.toList()),
          child: Text('common.save'.tr()),
        ),
      ],
    );
  }
}
