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
import 'note_tile.dart';
import 'study_actions.dart';
import 'study_format.dart';
import 'topic_tile.dart';

const double _contentMaxWidth = 760;

enum NotesScope
{
  topic,
  branch,
}

class TopicScreen extends ConsumerStatefulWidget
{
  final String topicId;

  const TopicScreen({super.key, required this.topicId});

  @override
  ConsumerState<TopicScreen> createState() => _TopicScreenState();
}

class _TopicScreenState extends ConsumerState<TopicScreen>
{
  NotesScope _scope = NotesScope.topic;
  List<StudyNote>? _notes;
  Object? _notesError;

  @override
  void initState()
  {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async
  {
    final scope = _scope;
    try
    {
      final notes = await ref.read(apiProv).getStudyNotes(widget.topicId, aIsBranch: scope == NotesScope.branch);
      if (mounted && scope == _scope)
      {
        setState(()
        {
          _notes = notes;
          _notesError = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted && scope == _scope)
      {
        setState(() => _notesError = aError);
      }
    }
  }

  void _setScope(NotesScope aScope)
  {
    setState(()
    {
      _scope = aScope;
      _notes = null;
      _notesError = null;
    });
    _loadNotes();
  }

  Future<void> _delete(StudyTopic aTopic) async
  {
    final isDeleted = await deleteTopicFlow(context, ref, aTopic);
    if (isDeleted && mounted)
    {
      closePage(context);
    }
  }

  Widget _sectionHeader(BuildContext aContext, {required IconData aIcon, required String aTitle, Widget? aAction})
  {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 4),
      child: Row(
        children: [
          Icon(aIcon, size: 18, color: aContext.palette.inkSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(aTitle, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
          if (aAction != null) aAction,
        ],
      ),
    );
  }

  Widget _breadcrumbs(BuildContext aContext, StudyTree aTree, StudyTopic aTopic)
  {
    final palette = aContext.palette;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          onPressed: () => context.pushReplacement(studyPath),
          child: Text('study.title'.tr()),
        ),
        for (final node in aTree.pathTo(aTopic.id)) ...[
          Icon(AppIcons.chevronRight, size: 14, color: palette.inkMuted),
          TextButton(
            onPressed: node.id == aTopic.id ? null : () => context.pushReplacement(topicPath(node.id)),
            child: Text(node.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ],
    );
  }

  Widget _progressCard(BuildContext aContext, StudyTopic aTopic)
  {
    final palette = aContext.palette;
    final progress = aTopic.progress;
    final percentText = 'study.percent'.tr(args: [studyNumber(aContext, progress.percent)]);
    final done = progress.done;
    final target = progress.target;
    final unit = progress.unit;
    final description = aTopic.description;

    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  percentText,
                  key: const ValueKey('topic.percent'),
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: progress.isComplete ? palette.positive : palette.inkPrimary),
                ),
                const SizedBox(width: 12),
                if (done != null && target != null && unit != null && unit != StudyUnit.percent)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        amountLine(aContext, done, target, unit),
                        key: const ValueKey('topic.amount'),
                        style: TextStyle(color: palette.inkSecondary),
                      ),
                    ),
                  )
                else
                  const Spacer(),
              ],
            ),
            const SizedBox(height: 8),
            StudyProgressBar(progress: progress, height: 10),
            const SizedBox(height: 8),
            if (progress.isAggregated)
              Text(
                unit == null ? 'study.aggregated_average'.tr() : 'study.aggregated_volume'.tr(),
                key: const ValueKey('topic.aggregated'),
                style: TextStyle(fontSize: 12, color: palette.inkMuted),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const ValueKey('topic.progress'),
                  onPressed: () => progressTopicFlow(context, ref, aTopic),
                  icon: const Icon(AppIcons.trendingUp, size: 18),
                  label: Text('study.update_progress'.tr()),
                ),
              ),
            if (description != null && description.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(description, style: TextStyle(color: palette.inkSecondary)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _subtopics(BuildContext aContext, StudyTree aTree, StudyTopic aTopic)
  {
    final palette = aContext.palette;
    final children = aTree.childrenOf(aTopic.id);
    final canAdd = aTree.canAddChild(aTopic);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          aContext,
          aIcon: AppIcons.listTree,
          aTitle: 'study.subtopics'.tr(),
          aAction: IconButton(
            key: const ValueKey('topic.add_child'),
            tooltip: 'study.add_child'.tr(),
            onPressed: canAdd ? () => createTopicFlow(context, ref, aParent: aTopic) : null,
            icon: Icon(AppIcons.plus, color: canAdd ? aContext.colors.primary : null),
          ),
        ),
        if (!canAdd)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(
              'study.depth_limit'.tr(args: ['${aTree.maxDepth}']),
              key: const ValueKey('topic.depth_limit'),
              style: TextStyle(fontSize: 12, color: palette.inkMuted),
            ),
          ),
        Card(
          margin: EdgeInsets.zero,
          semanticContainer: false,
          clipBehavior: Clip.antiAlias,
          child: children.isEmpty
              ? BlockEmpty(canAdd ? 'study.no_subtopics'.tr() : 'study.leaf_topic'.tr())
              : Column(
                  children: [
                    for (final child in children)
                      TopicTile(topic: child, onOpen: () => context.push(topicPath(child.id))),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _notesSection(BuildContext aContext, StudyTree aTree, StudyTopic aTopic)
  {
    final notes = _notes;
    final isBranch = _scope == NotesScope.branch;
    final Widget content;
    if (_notesError != null)
    {
      content = ErrorRetry(error: _notesError!, onRetry: _loadNotes);
    }
    else if (notes == null)
    {
      content = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else if (notes.isEmpty)
    {
      content = BlockEmpty(isBranch ? 'study.no_branch_notes'.tr() : 'study.no_notes'.tr());
    }
    else
    {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (index, note) in notes.indexed) ...[
            if (index > 0) const Divider(height: 1),
            StudyNoteTile(
              note: note,
              source: isBranch ? note.sourceRelativeTo(aTopic.depth) : const [],
              onOpen: () => editNoteFlow(context, ref, note, aTopicTitle: note.topicPath.join(pathSeparator)),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          aContext,
          aIcon: AppIcons.pencil,
          aTitle: 'study.notes'.tr(),
          aAction: IconButton(
            key: const ValueKey('topic.add_note'),
            tooltip: 'study.new_note'.tr(),
            onPressed: () => createNoteFlow(context, ref, aTopic, aTopicTitle: aTree.pathTo(aTopic.id).map((aItem) => aItem.title).join(pathSeparator)),
            icon: Icon(AppIcons.plus, color: aContext.colors.primary),
          ),
        ),
        if (aTopic.hasChildren)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<NotesScope>(
                  key: const ValueKey('topic.notes_scope'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: NotesScope.topic, label: Text('study.scope_topic'.tr())),
                    ButtonSegment(value: NotesScope.branch, icon: const Icon(AppIcons.listTree, size: 16), label: Text('study.scope_branch'.tr())),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (aSelected) => _setScope(aSelected.first),
                ),
              ),
            ),
          ),
        Card(margin: EdgeInsets.zero, semanticContainer: false, clipBehavior: Clip.antiAlias, child: content),
      ],
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(studyRevisionProv, (_, __) => _loadNotes());
    final treeAsync = ref.watch(studyTreeProv);
    final tree = treeAsync.valueOrNull;
    final topic = tree?.byId(widget.topicId);

    if (tree == null || topic == null)
    {
      final Widget body;
      if (treeAsync.hasError)
      {
        body = ErrorRetry(error: treeAsync.error!, onRetry: () => ref.invalidate(studyTreeProv));
      }
      else if (tree == null)
      {
        body = const Center(child: CircularProgressIndicator());
      }
      else
      {
        body = BlockEmpty('study.topic_missing'.tr());
      }
      return SubPage(title: 'study.title'.tr(), child: body);
    }

    return SubPage(
      title: topic.title,
      actions: [
        PopupMenuButton<String>(
          key: const ValueKey('topic.menu'),
          tooltip: 'common.actions'.tr(),
          icon: const Icon(AppIcons.moreVertical),
          onSelected: (aAction) => switch (aAction)
          {
            'edit' => editTopicFlow(context, ref, topic),
            'move' => moveTopicFlow(context, ref, tree, topic),
            _ => _delete(topic),
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text('study.edit_topic'.tr())),
            PopupMenuItem(value: 'move', child: Text('study.move'.tr())),
            PopupMenuItem(value: 'delete', enabled: !topic.hasChildren, child: Text('study.delete'.tr())),
          ],
        ),
      ],
      child: RefreshIndicator(
        onRefresh: () async
        {
          ref.invalidate(studyTreeProv);
          await _loadNotes();
        },
        child: ListView(
          padding: screenPadding(aContext),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _breadcrumbs(aContext, tree, topic),
                    const SizedBox(height: 8),
                    _progressCard(aContext, topic),
                    const SizedBox(height: 20),
                    _subtopics(aContext, tree, topic),
                    const SizedBox(height: 20),
                    _notesSection(aContext, tree, topic),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
