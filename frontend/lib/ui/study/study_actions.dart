import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import 'study_editors.dart';
import 'study_format.dart';

Future<T?> _run<T>(BuildContext aContext, WidgetRef aRef, Future<T> Function() aAction) async
{
  try
  {
    final result = await aAction();
    notifyStudyChanged(aRef);
    return result;
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

Future<StudyTopic?> createTopicFlow(BuildContext aContext, WidgetRef aRef, {StudyTopic? aParent}) async
{
  final draft = await showTopicEditor(aContext, aParentId: aParent?.id);
  if (draft == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).createTopic(draft));
}

Future<StudyTopic?> editTopicFlow(BuildContext aContext, WidgetRef aRef, StudyTopic aTopic) async
{
  final draft = await showTopicEditor(aContext, aTopic: aTopic);
  if (draft == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).updateTopic(aTopic.id, draft));
}

Future<StudyTopic?> progressTopicFlow(BuildContext aContext, WidgetRef aRef, StudyTopic aTopic) async
{
  final done = await showProgressDialog(aContext, aTopic);
  if (done == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).updateTopic(aTopic.id, TopicDraft.of(aTopic).copyWith(done: done)));
}

Future<StudyTopic?> moveTopicFlow(BuildContext aContext, WidgetRef aRef, StudyTree aTree, StudyTopic aTopic) async
{
  final target = await showMoveDialog(aContext, aTree, aTopic);
  if (target == null || !aContext.mounted)
  {
    return null;
  }
  final parent = target.parent;
  final draft = TopicDraft.of(aTopic).copyWith(parentId: parent?.id, isRoot: parent == null);
  return _run(aContext, aRef, () => aRef.read(apiProv).updateTopic(aTopic.id, draft));
}

Future<bool> deleteTopicFlow(BuildContext aContext, WidgetRef aRef, StudyTopic aTopic) async
{
  if (aTopic.hasChildren)
  {
    showInfoSnack(aContext, 'study.delete_has_children'.tr());
    return false;
  }
  final isConfirmed = await confirmAction(
    aContext,
    aTitle: 'study.delete_title'.tr(),
    aMessage: aTopic.noteCount > 0
        ? 'study.delete_message_notes'.tr(args: [aTopic.title, '${aTopic.noteCount}'])
        : 'study.delete_message'.tr(args: [aTopic.title]),
  );
  if (!isConfirmed || !aContext.mounted)
  {
    return false;
  }
  final result = await _run(aContext, aRef, () async
  {
    await aRef.read(apiProv).deleteTopic(aTopic.id);
    return true;
  });
  return result ?? false;
}

Future<StudyNote?> createNoteFlow(
  BuildContext aContext,
  WidgetRef aRef,
  StudyTopic aTopic,
  {
    DateTime? aInitialTs,
    String? aTopicTitle,
  }
) async
{
  final result = await showNoteEditor(aContext, aInitialTs: aInitialTs ?? DateTime.now(), aTopicTitle: aTopicTitle);
  final body = result?.body;
  if (result == null || body == null || !aContext.mounted)
  {
    return null;
  }
  return _run(aContext, aRef, () => aRef.read(apiProv).createStudyNote(aTopic.id, body, result.noteTs));
}

Future<bool> editNoteFlow(BuildContext aContext, WidgetRef aRef, StudyNote aNote, {String? aTopicTitle}) async
{
  final result = await showNoteEditor(aContext, aNote: aNote, aInitialTs: aNote.noteTs, aTopicTitle: aTopicTitle);
  if (result == null || !aContext.mounted)
  {
    return false;
  }
  if (result.isDelete)
  {
    final isConfirmed = await confirmAction(aContext, aTitle: 'study.delete_note_title'.tr(), aMessage: 'study.delete_note_message'.tr());
    if (!isConfirmed || !aContext.mounted)
    {
      return false;
    }
    final isDeleted = await _run(aContext, aRef, () async
    {
      await aRef.read(apiProv).deleteStudyNote(aNote.id);
      return true;
    });
    return isDeleted ?? false;
  }
  final body = result.body;
  if (body == null)
  {
    return false;
  }
  final note = await _run(aContext, aRef, () => aRef.read(apiProv).updateStudyNote(aNote.id, body, result.noteTs));
  return note != null;
}
