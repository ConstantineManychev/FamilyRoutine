import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'note_tile.dart';
import 'study_actions.dart';
import 'study_editors.dart';
import 'study_format.dart';
import 'topic_tile.dart';

DateTime noteTimeInBlock(DateTime aNow, DateTime aStart, DateTime? aEnd)
{
  if (aNow.isBefore(aStart))
  {
    return aStart;
  }
  if (aEnd != null && aNow.isAfter(aEnd))
  {
    return aEnd;
  }
  return aNow;
}

class StudyBlockPanel extends ConsumerStatefulWidget
{
  final String markId;
  final DateTime startTs;
  final DateTime? endTs;
  final MarkStudy study;
  final ValueChanged<String> onOpenAll;

  const StudyBlockPanel({
    super.key,
    required this.markId,
    required this.startTs,
    this.endTs,
    required this.study,
    required this.onOpenAll,
  });

  @override
  ConsumerState<StudyBlockPanel> createState() => _StudyBlockPanelState();
}

class _StudyBlockPanelState extends ConsumerState<StudyBlockPanel>
{
  late MarkStudy _study = widget.study;
  bool _isBusy = false;

  Future<void> _refresh() async
  {
    try
    {
      final details = await ref.read(apiProv).getMarkDetails(widget.markId);
      final study = details.study;
      if (mounted && study != null)
      {
        setState(() => _study = study);
      }
    }
    catch (_)
    {
      return;
    }
  }

  Future<void> _addNote() async
  {
    setState(() => _isBusy = true);
    StudyTree? tree;
    try
    {
      tree = await ref.read(apiProv).getStudyTree();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    if (mounted)
    {
      setState(() => _isBusy = false);
    }
    if (tree == null || !mounted)
    {
      return;
    }
    final topic = tree.topics.length == 1 ? tree.topics.first : await showTopicPicker(context, tree);
    if (topic == null || !mounted)
    {
      return;
    }
    final note = await createNoteFlow(
      context,
      ref,
      topic,
      aInitialTs: noteTimeInBlock(DateTime.now(), widget.startTs, widget.endTs),
      aTopicTitle: tree.pathTo(topic.id).map((aItem) => aItem.title).join(pathSeparator),
    );
    if (note != null)
    {
      await _refresh();
    }
  }

  Future<void> _addTopic() async
  {
    final topic = await createTopicFlow(context, ref);
    if (topic != null)
    {
      await _refresh();
    }
  }

  Future<void> _editNote(StudyNote aNote) async
  {
    final isChanged = await editNoteFlow(context, ref, aNote, aTopicTitle: aNote.topicPath.join(pathSeparator));
    if (isChanged)
    {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final topics = _study.topics;
    final notes = _study.notes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(AppIcons.graduationCap, size: 18, color: palette.inkSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('study.block_topics'.tr(), key: const ValueKey('study.block.title'), style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        if (topics.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('study.block_empty'.tr(), style: TextStyle(color: palette.inkMuted)),
          )
        else
          for (final topic in topics)
            TopicTile(topic: topic, onOpen: () => widget.onOpenAll(topicPath(topic.id))),
        const SizedBox(height: 8),
        Text('study.block_notes'.tr(), style: TextStyle(fontWeight: FontWeight.w700, color: palette.inkSecondary)),
        const SizedBox(height: 4),
        if (notes.isEmpty)
          Text('study.block_notes_empty'.tr(), style: TextStyle(color: palette.inkMuted))
        else
          for (final note in notes)
            StudyNoteTile(note: note, source: note.topicPath, onOpen: () => _editNote(note)),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: [
            if (topics.isEmpty)
              TextButton.icon(
                key: const ValueKey('study.block.add_topic'),
                onPressed: _addTopic,
                icon: const Icon(AppIcons.plus, size: 16),
                label: Text('study.new_topic'.tr()),
              )
            else
              TextButton.icon(
                key: const ValueKey('study.block.note'),
                onPressed: _isBusy ? null : _addNote,
                icon: const Icon(AppIcons.pencil, size: 16),
                label: Text('study.add_note'.tr()),
              ),
            TextButton.icon(
              key: const ValueKey('study.block.all'),
              onPressed: () => widget.onOpenAll(studyPath),
              icon: const Icon(AppIcons.chevronRight, size: 16),
              label: Text('study.all_topics'.tr()),
            ),
          ],
        ),
      ],
    );
  }
}
