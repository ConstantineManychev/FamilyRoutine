import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../nutrition/nutrition_format.dart';
import '../routine/mark_sheet.dart';
import '../routine/routine_style.dart';
import 'plan_content_editor.dart';
import 'planner_common.dart';

enum _PlanLeave { editDay, editSeries, openBlock, training }

class _PlanRoute
{
  final _PlanLeave kind;
  final String? target;
  final OccurrenceDetails? details;

  const _PlanRoute(this.kind, {this.target, this.details});
}

Future<void> showPlanOccurrence(BuildContext aContext, WidgetRef aRef, Occurrence aOccurrence) async
{
  while (true)
  {
    if (!aContext.mounted)
    {
      return;
    }
    final route = await showModalBottomSheet<_PlanRoute>(
      context: aContext,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PlanOccurrenceSheet(eventId: aOccurrence.eventId, occDate: aOccurrence.occDate),
    );
    if (route == null || !aContext.mounted)
    {
      return;
    }
    switch (route.kind)
    {
      case _PlanLeave.editDay:
        await Navigator.of(aContext).push<bool>(
          MaterialPageRoute(builder: (_) => PlanDayEditorScreen(details: route.details!)),
        );
        notifyPlannerChanged(aRef);
      case _PlanLeave.editSeries:
        await aContext.push('/app/planner/events/${aOccurrence.eventId}');
        notifyPlannerChanged(aRef);
      case _PlanLeave.openBlock:
        await openMarkSheet(aContext, route.target!);
        return;
      case _PlanLeave.training:
        await aContext.push('/app/training/sessions/${route.target}');
        notifyPlannerChanged(aRef);
        return;
    }
  }
}

class PlanContentView extends StatelessWidget
{
  final OccurrenceDetails details;

  const PlanContentView({super.key, required this.details});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final occurrence = details.occurrence;
    final content = details.content;
    final lines = <Widget>[];

    Widget line(String aText, {String? aTrailing, String? aSubtitle}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(aText),
                    if (aSubtitle != null) Text(aSubtitle, style: TextStyle(fontSize: 12, color: palette.inkMuted)),
                  ],
                ),
              ),
              if (aTrailing != null) Text(aTrailing, style: TextStyle(color: palette.inkSecondary)),
            ],
          ),
        );

    if (occurrence.isTraining)
    {
      lines.add(line(
        details.programName ?? occurrence.title,
        aSubtitle: details.dayName ?? 'planner.training_next_day'.tr(),
      ));
    }
    switch (occurrence.category)
    {
      case RoutineStatus.meal when content.foods.isNotEmpty:
        lines.addAll([
          for (final food in content.foods)
            line(food.title ?? 'nutrition.quick_title'.tr(), aTrailing: formatKcal(aContext, food.total.kcal)),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${'planner.content_total'.tr()}: ${formatKcal(aContext, content.total.kcal)} · ${macrosLine(aContext, content.total)}',
              key: const ValueKey('plan.total'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ]);
      case RoutineStatus.work when content.tasks.isNotEmpty:
        lines.addAll([for (final task in content.tasks) line('• ${task.title}')]);
      case RoutineStatus.school when content.studies.isNotEmpty:
        lines.addAll([for (final study in content.studies) line(study.topicTitle, aSubtitle: study.note)]);
      default:
        break;
    }
    final note = occurrence.note;
    if (note != null)
    {
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(note, style: TextStyle(color: palette.inkSecondary)),
      ));
    }
    if (lines.isEmpty)
    {
      lines.add(Text('planner.content_empty'.tr(), style: TextStyle(color: palette.inkMuted)));
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: palette.surfaceMuted, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: lines),
    );
  }
}

class PlanOccurrenceSheet extends ConsumerStatefulWidget
{
  final String eventId;
  final DateTime occDate;

  const PlanOccurrenceSheet({super.key, required this.eventId, required this.occDate});

  @override
  ConsumerState<PlanOccurrenceSheet> createState() => _PlanOccurrenceSheetState();
}

class _PlanOccurrenceSheetState extends ConsumerState<PlanOccurrenceSheet>
{
  OccurrenceDetails? _details;
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
      final details = await ref.read(apiProv).getOccurrence(widget.eventId, widget.occDate);
      if (mounted)
      {
        setState(()
        {
          _details = details;
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

  Future<void> _save(Occurrence aOccurrence, PlanState aState, {DateTime? aMovedStart}) async
  {
    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).saveOccurrence(aOccurrence.eventId, aOccurrence.occDate, aState, aMovedStart: aMovedStart);
      notifyPlannerChanged(ref);
      notifyNutritionChanged(ref);
      await _load();
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

  Future<void> _move(Occurrence aOccurrence) async
  {
    final start = await pickMoveStart(context, aOccurrence);
    if (start != null && mounted)
    {
      await _save(aOccurrence, aOccurrence.state, aMovedStart: start);
    }
  }

  Future<void> _startTraining(Occurrence aOccurrence) async
  {
    final sessionId = aOccurrence.sessionId;
    if (aOccurrence.isSessionActive && sessionId != null)
    {
      Navigator.of(context).pop(_PlanRoute(_PlanLeave.training, target: sessionId));
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      final session = await ref.read(apiProv).startOccurrence(aOccurrence.eventId, aOccurrence.occDate);
      notifyPlannerChanged(ref);
      if (mounted)
      {
        Navigator.of(context).pop(_PlanRoute(_PlanLeave.training, target: session.id));
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

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final media = MediaQuery.of(aContext);
    final details = _details;
    if (details == null)
    {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: _error != null
            ? ErrorRetry(error: _error!, onRetry: _load)
            : const SizedBox(height: 160, child: Center(child: CircularProgressIndicator())),
      );
    }

    final palette = aContext.palette;
    final item = details.occurrence;
    final status = item.category ?? RoutineStatus.other;
    final color = status.colorOf(aContext);
    final isOpen = !item.isDone && !item.isSkipped;
    final isToday = DateUtils.isSameDay(item.startTs, DateTime.now());
    final stateKey = item.isDone ? 'routine.plan_done' : (item.isSkipped ? 'routine.plan_skipped' : 'routine.plan_waiting');
    final markId = item.statusMarkId;
    void leave(_PlanRoute aRoute) => Navigator.of(aContext).pop(aRoute);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + media.padding.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
                  child: Icon(status.icon, size: 20, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(
                        '${DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(item.startTs)} · ${occurrenceTimeLabel(aContext, item)}',
                        style: TextStyle(color: palette.inkSecondary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [stateKey.tr(), if (details.isCustom) 'planner.day_custom'.tr()].join(' · '),
                        key: const ValueKey('plan.state'),
                        style: TextStyle(fontSize: 12, color: palette.inkMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            PlanContentView(details: details),
            if (isOpen && (hasPlanContent(item.category) || item.isTraining))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('planner.apply_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isOpen)
                  FilledButton.icon(
                    key: const ValueKey('plan.done'),
                    onPressed: _isBusy ? null : () => _save(item, PlanState.done),
                    icon: const Icon(AppIcons.checkCircle, size: 16),
                    label: Text('planner.done'.tr()),
                  )
                else
                  OutlinedButton.icon(
                    key: const ValueKey('plan.undo'),
                    onPressed: _isBusy ? null : () => _save(item, PlanState.planned),
                    icon: const Icon(AppIcons.history, size: 16),
                    label: Text(item.isDone ? 'planner.undo_done'.tr() : 'planner.unskip'.tr()),
                  ),
                if (item.isTraining && isOpen && (isToday || item.isSessionActive))
                  FilledButton.tonalIcon(
                    key: const ValueKey('plan.training'),
                    onPressed: _isBusy ? null : () => _startTraining(item),
                    icon: const Icon(AppIcons.dumbbell, size: 16),
                    label: Text(item.isSessionActive ? 'planner.continue_training'.tr() : 'planner.start_training'.tr()),
                  ),
                if (!item.isTraining && isOpen && isToday)
                  OutlinedButton.icon(
                    key: const ValueKey('plan.now'),
                    onPressed: _isBusy ? null : () => _save(item, PlanState.done, aMovedStart: currentMinute()),
                    icon: const Icon(AppIcons.zap, size: 16),
                    label: Text('routine.plan_now'.tr()),
                  ),
                if (item.isDone && markId != null)
                  OutlinedButton.icon(
                    key: const ValueKey('plan.open_block'),
                    onPressed: _isBusy ? null : () => leave(_PlanRoute(_PlanLeave.openBlock, target: markId)),
                    icon: const Icon(AppIcons.chevronRight, size: 16),
                    label: Text('planner.open_block'.tr()),
                  ),
                OutlinedButton.icon(
                  key: const ValueKey('plan.move'),
                  onPressed: _isBusy ? null : () => _move(item),
                  icon: const Icon(AppIcons.calendarClock, size: 16),
                  label: Text('planner.move'.tr()),
                ),
                if (isOpen)
                  TextButton.icon(
                    key: const ValueKey('plan.skip'),
                    onPressed: _isBusy ? null : () => _save(item, PlanState.skipped),
                    icon: const Icon(AppIcons.x, size: 16),
                    label: Text('planner.skip'.tr()),
                  ),
              ],
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!item.isDone && (hasPlanContent(item.category) || item.isTraining))
                  TextButton.icon(
                    key: const ValueKey('plan.edit_day'),
                    onPressed: _isBusy ? null : () => leave(_PlanRoute(_PlanLeave.editDay, details: details)),
                    icon: const Icon(AppIcons.edit, size: 16),
                    label: Text('planner.edit_day'.tr()),
                  ),
                TextButton.icon(
                  key: const ValueKey('plan.edit_series'),
                  onPressed: _isBusy ? null : () => leave(const _PlanRoute(_PlanLeave.editSeries)),
                  icon: const Icon(AppIcons.calendarClock, size: 16),
                  label: Text('planner.edit_series'.tr()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class PlanDayEditorScreen extends ConsumerStatefulWidget
{
  final OccurrenceDetails details;

  const PlanDayEditorScreen({super.key, required this.details});

  @override
  ConsumerState<PlanDayEditorScreen> createState() => _PlanDayEditorScreenState();
}

class _PlanDayEditorScreenState extends ConsumerState<PlanDayEditorScreen>
{
  late final PlanContentDraft _draft = PlanContentDraft.of(widget.details.content);
  late String? _dayId = widget.details.isCustom ? widget.details.dayId : null;
  List<ProgramDay> _days = const [];
  bool _isBusy = false;

  Occurrence get _occurrence => widget.details.occurrence;

  @override
  void initState()
  {
    super.initState();
    _loadDays();
  }

  Future<void> _loadDays() async
  {
    final programId = _occurrence.programId;
    if (programId == null)
    {
      return;
    }
    try
    {
      final program = await ref.read(apiProv).getProgram(programId);
      if (mounted)
      {
        setState(() => _days = program.days.where((aDay) => aDay.id != null).toList());
      }
    }
    catch (_)
    {
      if (mounted)
      {
        setState(() => _days = const []);
      }
    }
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
      if (mounted)
      {
        Navigator.of(context).pop(true);
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

  Future<void> _save() => _run(() async
      {
        await ref.read(apiProv).saveOccurrenceContent(_occurrence.eventId, _occurrence.occDate, {
          ..._draft.toJson(_occurrence.category),
          if (_dayId != null) 'day_id': _dayId,
        });
      });

  Future<void> _reset() => _run(() async
      {
        await ref.read(apiProv).resetOccurrenceContent(_occurrence.eventId, _occurrence.occDate);
      });

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final me = ref.watch(sessionUserIdProv);
    final ownerId = widget.details.ownerId;
    final date = DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(_occurrence.startTs);

    return SubPage(
      title: 'planner.edit_day_title'.tr(args: [_occurrence.title, date]),
      actions: [
        TextButton(
          key: const ValueKey('plan.day_save'),
          onPressed: _isBusy ? null : _save,
          child: Text('common.save'.tr()),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('planner.edit_day_hint'.tr(), style: TextStyle(color: aContext.palette.inkSecondary)),
          const SizedBox(height: 16),
          if (_occurrence.isTraining) ...[
            DropdownButtonFormField<String?>(
              key: ValueKey('plan.day.${_days.length}'),
              initialValue: _days.any((aDay) => aDay.id == _dayId) ? _dayId : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'planner.training_day'.tr(), border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(value: null, child: Text('planner.training_day_same'.tr())),
                for (final day in _days) DropdownMenuItem(value: day.id, child: Text(day.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _isBusy ? null : (aValue) => setState(() => _dayId = aValue),
            ),
            const SizedBox(height: 16),
          ],
          PlanContentEditor(
            category: _occurrence.category,
            draft: _draft,
            personId: ownerId == me ? null : ownerId,
            isEnabled: !_isBusy,
          ),
          if (widget.details.isCustom) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('plan.day_reset'),
                onPressed: _isBusy ? null : _reset,
                icon: const Icon(AppIcons.history, size: 16),
                label: Text('planner.reset_day'.tr()),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
