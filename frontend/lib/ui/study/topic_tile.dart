import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'study_format.dart';

const double _indentStep = 16;
const int _maxIndentLevels = 4;

String topicSummary(BuildContext aContext, StudyTopic aTopic) => [
      progressLine(aContext, aTopic.progress),
      if (aTopic.hasChildren) 'study.subtopics_count'.plural(aTopic.childCount),
      if (aTopic.noteCount > 0) 'study.notes_count'.plural(aTopic.noteCount),
    ].join(' · ');

class TopicTile extends StatelessWidget
{
  final StudyTopic topic;
  final int indent;
  final bool? isExpanded;
  final VoidCallback onOpen;
  final VoidCallback? onToggleExpand;

  const TopicTile({super.key, required this.topic, required this.onOpen, this.indent = 0, this.isExpanded, this.onToggleExpand});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final expanded = isExpanded;
    final toggle = onToggleExpand;

    return ListTile(
      key: ValueKey('topic.tile.${topic.id}'),
      contentPadding: EdgeInsets.only(left: 4 + _indentStep * indent.clamp(0, _maxIndentLevels), right: 8),
      minLeadingWidth: 32,
      horizontalTitleGap: 4,
      onTap: onOpen,
      leading: expanded == null || toggle == null
          ? SizedBox(width: 40, child: Icon(AppIcons.circleDot, size: 12, color: palette.inkMuted))
          : IconButton(
              key: ValueKey('topic.expand.${topic.id}'),
              tooltip: expanded ? 'study.collapse'.tr() : 'study.expand'.tr(),
              onPressed: toggle,
              icon: Icon(expanded ? AppIcons.chevronDown : AppIcons.chevronRight, size: 18),
            ),
      title: Text(topic.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          ExcludeSemantics(child: StudyProgressBar(progress: topic.progress, height: 5)),
          const SizedBox(height: 3),
          Text(topicSummary(aContext, topic), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: palette.inkMuted)),
        ],
      ),
      trailing: Icon(AppIcons.chevronRight, size: 18, color: palette.inkMuted),
    );
  }
}
