import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'work_format.dart';

class TaskTile extends StatelessWidget
{
  final WorkTask task;
  final DateTime day;
  final VoidCallback onOpen;
  final VoidCallback? onToggle;
  final VoidCallback? onReport;

  const TaskTile({super.key, required this.task, required this.day, required this.onOpen, this.onToggle, this.onReport});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final isDone = task.isDoneOn(day);
    final report = task.lastReport;
    final toggle = onToggle;
    final addReport = onReport;

    return ListTile(
      key: ValueKey('task.tile.${task.id}'),
      contentPadding: const EdgeInsets.only(left: 4, right: 4),
      onTap: onOpen,
      leading: Checkbox(
        value: isDone,
        onChanged: toggle == null ? null : (_) => toggle(),
      ),
      title: Text(
        task.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          decoration: isDone ? TextDecoration.lineThrough : null,
          color: isDone ? palette.inkMuted : palette.inkPrimary,
        ),
      ),
      subtitle: Text(
        [
          taskStatusLine(aContext, task, day),
          if (report != null) 'work.last_report'.tr(args: [report]),
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: addReport == null
          ? const Icon(AppIcons.chevronRight, size: 18)
          : IconButton(
              key: ValueKey('task.report.${task.id}'),
              tooltip: 'work.add_report'.tr(),
              onPressed: addReport,
              icon: Icon(AppIcons.listChecks, size: 18, color: aContext.colors.primary),
            ),
    );
  }
}
