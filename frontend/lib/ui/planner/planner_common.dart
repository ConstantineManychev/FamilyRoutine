import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../routine/routine_style.dart';
import '../training/training_revision.dart';

final StateProvider<int> plannerRevisionProv = StateProvider<int>((aRef) => 0);

void notifyPlannerChanged(WidgetRef aRef)
{
  aRef.read(plannerRevisionProv.notifier).state++;
  notifyTrainingChanged(aRef);
}

DateTime dayOnly(DateTime aValue) => DateTime(aValue.year, aValue.month, aValue.day);

DateTime shiftDays(DateTime aDate, int aDays) => DateTime(aDate.year, aDate.month, aDate.day + aDays);

String minutesLabel(int aMinutes) => formatDuration(Duration(minutes: aMinutes));

String occurrenceTimeLabel(BuildContext aContext, Occurrence aOccurrence)
{
  final start = formatClock(aContext, aOccurrence.startTs);
  final end = formatClock(aContext, aOccurrence.endTs);
  return aOccurrence.timing == PlanTiming.fixed
      ? '$start–$end'
      : 'planner.window_label'.tr(args: [start, end, minutesLabel(aOccurrence.durationMin)]);
}

bool isOccurrenceNow(Occurrence aOccurrence, DateTime aNow) =>
    aOccurrence.state == PlanState.planned && !aOccurrence.startTs.isAfter(aNow) && aOccurrence.endTs.isAfter(aNow);

Future<void> startTrainingSlot(BuildContext aContext, WidgetRef aRef, String aEventId, DateTime aOccDate) async
{
  try
  {
    final session = await aRef.read(apiProv).startOccurrence(aEventId, aOccDate);
    notifyPlannerChanged(aRef);
    if (aContext.mounted)
    {
      await aContext.push('/app/training/sessions/${session.id}');
      notifyPlannerChanged(aRef);
    }
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
  }
}

Future<void> openSession(BuildContext aContext, WidgetRef aRef, String aSessionId) async
{
  await aContext.push('/app/training/sessions/$aSessionId');
  notifyPlannerChanged(aRef);
}

Future<void> startOrContinueTraining(BuildContext aContext, WidgetRef aRef, Occurrence aOccurrence) async
{
  final sessionId = aOccurrence.sessionId;
  if (aOccurrence.isSessionActive && sessionId != null)
  {
    await openSession(aContext, aRef, sessionId);
  }
  else
  {
    await startTrainingSlot(aContext, aRef, aOccurrence.eventId, aOccurrence.occDate);
  }
}

class OccurrenceList extends ConsumerWidget
{
  final List<Occurrence> occurrences;
  final DateTime now;

  const OccurrenceList({super.key, required this.occurrences, required this.now});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    return Column(
      children: [
        for (final item in occurrences)
          OccurrenceTile(
            key: ValueKey(item.key),
            occurrence: item,
            isNow: isOccurrenceNow(item, now),
            isToday: DateUtils.isSameDay(item.startTs, now),
            onTap: () => showOccurrenceActions(aContext, aRef, item),
            onDoneChanged: (aIsDone) => setOccurrenceState(aContext, aRef, item, aIsDone ? PlanState.done : PlanState.planned),
            onStartTraining: () => startOrContinueTraining(aContext, aRef, item),
          ),
      ],
    );
  }
}

class OccurrenceTile extends StatelessWidget
{
  final Occurrence occurrence;
  final bool isNow;
  final bool isToday;
  final VoidCallback onTap;
  final ValueChanged<bool> onDoneChanged;
  final VoidCallback onStartTraining;

  const OccurrenceTile({
    super.key,
    required this.occurrence,
    required this.isNow,
    required this.isToday,
    required this.onTap,
    required this.onDoneChanged,
    required this.onStartTraining,
  });

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final item = occurrence;
    final category = item.category;
    final color = category?.colorOf(aContext) ?? palette.inkSecondary;
    final isMuted = item.isDone || item.isSkipped;
    final showsIssues = item.state == PlanState.planned;
    final details = [
      occurrenceTimeLabel(aContext, item),
      if (item.isTraining) item.dayName ?? 'planner.training_next_day'.tr(),
      if (item.isMoved) 'planner.moved'.tr(),
      if (item.isSkipped) 'planner.skipped'.tr(),
    ].join(' · ');

    final canStartTraining = item.isTraining && !item.isDone && !item.isSkipped && (isToday || item.isSessionActive);
    final Widget? trailing;
    if (item.isTraining && item.isDone)
    {
      trailing = Icon(AppIcons.checkCircle, color: palette.positive);
    }
    else if (item.isTraining)
    {
      trailing = null;
    }
    else
    {
      trailing = Checkbox(
        value: item.isDone,
        onChanged: item.isSkipped ? null : (aValue) => onDoneChanged(aValue ?? false),
      );
    }

    return Semantics(
      button: true,
      container: true,
      label: item.title,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: isNow
              ? BoxDecoration(
                  color: aContext.colors.primaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withValues(alpha: 0.15),
                child: Icon(category?.icon ?? AppIcons.calendar, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isMuted ? palette.inkMuted : palette.inkPrimary,
                              decoration: item.isSkipped ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                        if (item.repeat != PlanRepeat.once) ...[
                          const SizedBox(width: 6),
                          Icon(AppIcons.refreshCw, size: 12, color: palette.inkMuted, semanticLabel: 'planner.repeats_badge'.tr()),
                        ],
                        if (isNow) ...[
                          const SizedBox(width: 8),
                          Text('planner.now'.tr(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: aContext.colors.primary)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(details, style: TextStyle(fontSize: 13, color: palette.inkSecondary)),
                    if (showsIssues && item.conflicts.isNotEmpty)
                      _Issue(
                        icon: AppIcons.alertCircle,
                        color: palette.danger,
                        text: 'planner.conflict'.tr(args: [item.conflicts.map((aRef) => aRef.title).toSet().join(', ')]),
                      ),
                    if (showsIssues && item.overload != null)
                      _Issue(
                        icon: AppIcons.clock,
                        color: palette.warning,
                        text: 'planner.overload'.tr(args: [
                          minutesLabel(item.overload!.busyMin),
                          minutesLabel(item.overload!.windowMin),
                        ]),
                      ),
                    if (canStartTraining) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: onStartTraining,
                        icon: const Icon(AppIcons.dumbbell, size: 18),
                        label: Text(
                          item.isSessionActive ? 'planner.continue_training'.tr() : 'planner.start_training'.tr(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Issue extends StatelessWidget
{
  final IconData icon;
  final Color color;
  final String text;

  const _Issue({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext aContext)
  {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color))),
        ],
      ),
    );
  }
}

enum _OccurrenceAction { done, planned, skip, move, startTraining, startStatus, edit }

Future<void> setOccurrenceState(BuildContext aContext, WidgetRef aRef, Occurrence aOccurrence, PlanState aState) async
{
  try
  {
    await aRef.read(apiProv).saveOccurrence(aOccurrence.eventId, aOccurrence.occDate, aState);
    notifyPlannerChanged(aRef);
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
  }
}

Future<void> showOccurrenceActions(BuildContext aContext, WidgetRef aRef, Occurrence aOccurrence) async
{
  final item = aOccurrence;
  final isToday = DateUtils.isSameDay(item.startTs, DateTime.now());
  final action = await showModalBottomSheet<_OccurrenceAction>(
    context: aContext,
    useRootNavigator: true,
    builder: (aSheetContext)
    {
      Widget tile(_OccurrenceAction aAction, IconData aIcon, String aLabel) => ListTile(
            leading: Icon(aIcon),
            title: Text(aLabel),
            onTap: () => Navigator.of(aSheetContext).pop(aAction),
          );

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(item.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${DateFormat.MMMEd(aContext.locale.toLanguageTag()).format(item.startTs)} · ${occurrenceTimeLabel(aContext, item)}'),
              ),
              const Divider(height: 1),
              if (item.isTraining && !item.isDone && (isToday || item.isSessionActive))
                tile(
                  _OccurrenceAction.startTraining,
                  AppIcons.dumbbell,
                  item.isSessionActive ? 'planner.continue_training'.tr() : 'planner.start_training'.tr(),
                ),
              if (!item.isTraining && item.category != null && isToday && !item.isDone)
                tile(_OccurrenceAction.startStatus, item.category!.icon, 'planner.start_status'.tr(args: [item.category!.label])),
              if (!item.isDone && !item.isSkipped) tile(_OccurrenceAction.done, AppIcons.checkCircle, 'planner.done'.tr()),
              if (item.isDone || item.isSkipped)
                tile(_OccurrenceAction.planned, AppIcons.history, item.isDone ? 'planner.undo_done'.tr() : 'planner.unskip'.tr()),
              if (!item.isSkipped && !item.isDone) tile(_OccurrenceAction.skip, AppIcons.x, 'planner.skip'.tr()),
              tile(_OccurrenceAction.move, AppIcons.calendarClock, 'planner.move'.tr()),
              tile(_OccurrenceAction.edit, AppIcons.edit, 'planner.edit_series'.tr()),
            ],
          ),
        ),
      );
    },
  );
  if (action == null || !aContext.mounted)
  {
    return;
  }

  switch (action)
  {
    case _OccurrenceAction.done:
      await setOccurrenceState(aContext, aRef, item, PlanState.done);
    case _OccurrenceAction.planned:
      await setOccurrenceState(aContext, aRef, item, PlanState.planned);
    case _OccurrenceAction.skip:
      await setOccurrenceState(aContext, aRef, item, PlanState.skipped);
    case _OccurrenceAction.move:
      await _move(aContext, aRef, item);
    case _OccurrenceAction.startTraining:
      await startOrContinueTraining(aContext, aRef, item);
    case _OccurrenceAction.startStatus:
      await _startStatus(aContext, aRef, item);
    case _OccurrenceAction.edit:
      await aContext.push('/app/planner/events/${item.eventId}');
      notifyPlannerChanged(aRef);
  }
}

Future<void> _move(BuildContext aContext, WidgetRef aRef, Occurrence aOccurrence) async
{
  final now = DateTime.now();
  final date = await showDatePicker(
    context: aContext,
    initialDate: aOccurrence.startTs,
    firstDate: now.subtract(const Duration(days: 365)),
    lastDate: now.add(const Duration(days: 365)),
    helpText: 'planner.move_title'.tr(),
  );
  if (date == null || !aContext.mounted)
  {
    return;
  }
  final time = await showTimePicker(
    context: aContext,
    initialTime: TimeOfDay.fromDateTime(aOccurrence.startTs),
    helpText: 'planner.move_title'.tr(),
  );
  if (time == null || !aContext.mounted)
  {
    return;
  }

  try
  {
    await aRef.read(apiProv).saveOccurrence(
          aOccurrence.eventId,
          aOccurrence.occDate,
          aOccurrence.state,
          aMovedStart: DateTime(date.year, date.month, date.day, time.hour, time.minute),
        );
    notifyPlannerChanged(aRef);
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
  }
}

Future<void> _startStatus(BuildContext aContext, WidgetRef aRef, Occurrence aOccurrence) async
{
  final status = aOccurrence.category;
  if (status == null)
  {
    return;
  }
  try
  {
    await aRef.read(apiProv).createMark(status, aNote: aOccurrence.title);
    aRef.read(routineRevisionProv.notifier).state++;
    if (aContext.mounted)
    {
      showInfoSnack(aContext, 'planner.status_started'.tr(args: [status.label]));
    }
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
  }
}
