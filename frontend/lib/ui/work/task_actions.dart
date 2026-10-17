import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import 'task_editor.dart';
import 'work_format.dart';

Future<TaskDetails?> _run(BuildContext aContext, WidgetRef aRef, Future<TaskDetails> Function() aAction) async
{
  try
  {
    final details = await aAction();
    notifyWorkChanged(aRef);
    return details;
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
    return null;
  }
}

Future<TaskDetails?> createTaskFlow(BuildContext aContext, WidgetRef aRef, DateTime aDate, {TaskKind aKind = TaskKind.day}) async
{
  final draft = await showTaskEditor(aContext, aDate: aDate, aKind: aKind);
  if (draft == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).createTask(draft));
}

Future<TaskDetails?> editTaskFlow(BuildContext aContext, WidgetRef aRef, WorkTask aTask) async
{
  final draft = await showTaskEditor(aContext, aTask: aTask, aDate: aTask.startOn);
  if (draft == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).updateTask(aTask.id, draft));
}

Future<TaskDetails?> completeTaskFlow(BuildContext aContext, WidgetRef aRef, WorkTask aTask, DateTime aDay, {String? aMarkId}) async
{
  final report = await showReportDialog(aContext, aTitle: 'work.complete_title'.tr(args: [aTask.title]), aHint: 'work.report_hint'.tr());
  if (report == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).logTask(aTask.id, TaskAction.done, aDay, aReport: report, aMarkId: aMarkId));
}

Future<TaskDetails?> progressTaskFlow(BuildContext aContext, WidgetRef aRef, WorkTask aTask, DateTime aDay, {String? aMarkId}) async
{
  final report = await showReportDialog(
    aContext,
    aTitle: 'work.progress_title'.tr(args: [aTask.title]),
    aHint: 'work.report_hint'.tr(),
    aIsRequired: true,
  );
  if (report == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).logTask(aTask.id, TaskAction.progress, aDay, aReport: report, aMarkId: aMarkId));
}

Future<TaskDetails?> reopenTaskFlow(BuildContext aContext, WidgetRef aRef, WorkTask aTask, DateTime aDay) async
{
  final reason = await showReportDialog(aContext, aTitle: 'work.reopen_title'.tr(args: [aTask.title]), aHint: 'work.reopen_hint'.tr());
  if (reason == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).logTask(aTask.id, TaskAction.reopen, aDay, aReport: reason));
}

Future<bool> archiveTaskFlow(BuildContext aContext, WidgetRef aRef, WorkTask aTask) async
{
  final isConfirmed = await confirmAction(
    aContext,
    aTitle: 'work.archive_title'.tr(),
    aMessage: 'work.archive_message'.tr(args: [aTask.title]),
  );
  if (!isConfirmed || !aContext.mounted)
  {
    return false;
  }
  try
  {
    await aRef.read(apiProv).archiveTask(aTask.id);
    notifyWorkChanged(aRef);
    return true;
  }
  catch (aError)
  {
    if (aContext.mounted)
    {
      showErrorSnack(aContext, aError);
    }
    return false;
  }
}
