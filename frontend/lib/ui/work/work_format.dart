import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../routine/routine_style.dart';

final StateProvider<int> workRevisionProv = StateProvider<int>((aRef) => 0);

void notifyWorkChanged(WidgetRef aRef)
{
  aRef.read(workRevisionProv.notifier).state++;
  aRef.read(routineRevisionProv.notifier).state++;
}

String workPath(DateTime aDate) => Uri(path: '/app/work', queryParameters: {'date': dateWire(aDate)}).toString();

String taskKindLabel(TaskKind aKind) => 'work.kind_${aKind.name}'.tr();

String shortDate(BuildContext aContext, DateTime aDate) => DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aDate);

String eventStamp(BuildContext aContext, DateTime aTs) =>
    '${DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aTs)}, ${formatClock(aContext, aTs)}';

IconData eventIcon(TaskEventKind aKind) => switch (aKind)
{
  TaskEventKind.created => AppIcons.plusCircle,
  TaskEventKind.edited => AppIcons.pencil,
  TaskEventKind.progress => AppIcons.listChecks,
  TaskEventKind.done => AppIcons.checkCircle,
  TaskEventKind.reopened => AppIcons.refreshCw,
  TaskEventKind.deleted => AppIcons.trash2,
};

String _fieldValue(BuildContext aContext, TaskField aField, String? aValue)
{
  if (aValue == null || aValue.isEmpty)
  {
    return 'work.empty_value'.tr();
  }
  return switch (aField)
  {
    TaskField.kind => taskKindLabel(TaskKind.parse(aValue)),
    TaskField.date => shortDate(aContext, parseDateWire(aValue)),
    _ => '«$aValue»',
  };
}

String eventTitle(BuildContext aContext, TaskEvent aEvent)
{
  final field = aEvent.field;
  return switch (aEvent.kind)
  {
    TaskEventKind.edited when field != null => 'work.edit_line'.tr(args: [
        'work.field_${field.name}'.tr(),
        _fieldValue(aContext, field, aEvent.oldValue),
        _fieldValue(aContext, field, aEvent.newValue),
      ]),
    TaskEventKind.done => 'work.event_done'.tr(args: [shortDate(aContext, aEvent.eventOn)]),
    TaskEventKind.progress => 'work.event_progress'.tr(args: [shortDate(aContext, aEvent.eventOn)]),
    _ => 'work.event_${aEvent.kind.name}'.tr(),
  };
}

String taskStatusLine(BuildContext aContext, WorkTask aTask, DateTime aDay)
{
  final doneOn = aTask.doneOn;
  if (doneOn != null && !doneOn.isAfter(aDay))
  {
    return 'work.done_on'.tr(args: [shortDate(aContext, doneOn)]);
  }
  if (aTask.kind == TaskKind.day)
  {
    return doneOn == null ? 'work.day_only'.tr() : 'work.done_on'.tr(args: [shortDate(aContext, doneOn)]);
  }
  final carried = aTask.carriedDays(aDay);
  if (doneOn != null)
  {
    return 'work.closed_later'.tr(args: [shortDate(aContext, doneOn)]);
  }
  return carried <= 0 ? 'work.new_general'.tr() : 'work.carried'.tr(args: [shortDate(aContext, aTask.startOn), '${carried + 1}']);
}
