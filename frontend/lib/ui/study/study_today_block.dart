import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'study_actions.dart';
import 'study_format.dart';
import 'topic_tile.dart';

const int _shownTopics = 5;

class StudyTodayBlock extends ConsumerWidget
{
  const StudyTodayBlock({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final treeAsync = aRef.watch(studyTreeProv);
    final Widget content = treeAsync.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(studyTreeProv)),
      data: (aTree)
      {
        final roots = aTree.roots;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (roots.isEmpty)
              BlockEmpty('study.today_empty'.tr())
            else
              for (final topic in roots.take(_shownTopics))
                TopicTile(topic: topic, onOpen: () => aContext.push(topicPath(topic.id))),
            if (roots.length > _shownTopics)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  'study.more_topics'.tr(args: ['${roots.length - _shownTopics}']),
                  style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted),
                ),
              ),
          ],
        );
      },
    );

    return BlockCard(
      title: 'study.title'.tr(),
      onAdd: () => createTopicFlow(aContext, aRef),
      addTooltip: 'study.new_root'.tr(),
      onExpand: () => aContext.push(studyPath),
      child: content,
    );
  }
}
