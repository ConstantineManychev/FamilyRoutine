import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'study_actions.dart';
import 'study_format.dart';
import 'topic_tile.dart';

const double _contentMaxWidth = 760;

class StudyScreen extends ConsumerStatefulWidget
{
  const StudyScreen({super.key});

  @override
  ConsumerState<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends ConsumerState<StudyScreen>
{
  final Set<String> _collapsed = {};

  Future<void> _open(String aId) async
  {
    await context.push(topicPath(aId));
  }

  void _toggle(String aId)
  {
    setState(() => _collapsed.contains(aId) ? _collapsed.remove(aId) : _collapsed.add(aId));
  }

  List<Widget> _branch(StudyTree aTree, List<StudyTopic> aTopics, int aIndent)
  {
    final tiles = <Widget>[];
    for (final topic in aTopics)
    {
      final isExpanded = !_collapsed.contains(topic.id);
      tiles.add(TopicTile(
        topic: topic,
        indent: aIndent,
        isExpanded: topic.hasChildren ? isExpanded : null,
        onToggleExpand: topic.hasChildren ? () => _toggle(topic.id) : null,
        onOpen: () => _open(topic.id),
      ));
      if (topic.hasChildren && isExpanded)
      {
        tiles.addAll(_branch(aTree, aTree.childrenOf(topic.id), aIndent + 1));
      }
    }
    return tiles;
  }

  List<Widget> _found(BuildContext aContext, StudyTree aTree, String aQuery)
  {
    final found = aTree.depthFirst().where((aTopic) => aTopic.title.toLowerCase().contains(aQuery)).toList();
    if (found.isEmpty)
    {
      return [BlockEmpty('study.nothing_found'.tr())];
    }
    return [
      for (final topic in found)
        ListTile(
          key: ValueKey('topic.found.${topic.id}'),
          onTap: () => _open(topic.id),
          title: Text(topic.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              if (topic.parentId != null) aTree.pathTo(topic.id).map((aItem) => aItem.title).join(' › '),
              progressLine(aContext, topic.progress),
            ].join('\n'),
            style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
          ),
        ),
    ];
  }

  Widget _list(BuildContext aContext, String aQuery)
  {
    final treeAsync = ref.watch(studyTreeProv);
    return treeAsync.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => ref.invalidate(studyTreeProv)),
      data: (aTree)
      {
        final palette = aContext.palette;
        final List<Widget> tiles;
        if (aTree.topics.isEmpty)
        {
          tiles = [BlockEmpty('study.empty'.tr())];
        }
        else if (aQuery.isNotEmpty)
        {
          tiles = _found(aContext, aTree, aQuery);
        }
        else
        {
          tiles = _branch(aTree, aTree.roots, 0);
        }
        return RefreshIndicator(
          onRefresh: () => ref.refresh(studyTreeProv.future),
          child: ListView(
            padding: const EdgeInsets.only(bottom: fabClearance),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text(
                          'study.screen_hint'.tr(args: ['${aTree.maxDepth}']),
                          style: TextStyle(fontSize: 12, color: palette.inkMuted),
                        ),
                      ),
                      ...tiles,
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    return ListPage(
      title: 'study.title'.tr(),
      addTooltip: 'study.new_root'.tr(),
      onAdd: () => createTopicFlow(aContext, ref),
      searchHint: 'study.search'.tr(),
      builder: _list,
    );
  }
}
