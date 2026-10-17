import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import 'study_format.dart';

const String pathSeparator = ' › ';

class StudyNoteTile extends StatelessWidget
{
  final StudyNote note;
  final List<String> source;
  final VoidCallback? onOpen;

  const StudyNoteTile({super.key, required this.note, this.source = const [], this.onOpen});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    return InkWell(
      key: ValueKey('note.tile.${note.id}'),
      onTap: onOpen,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(AppIcons.clock, size: 14, color: palette.inkMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(noteStamp(aContext, note.noteTs), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
                ),
              ],
            ),
            if (source.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(AppIcons.listTree, size: 14, color: aContext.colors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        source.join(pathSeparator),
                        key: ValueKey('note.source.${note.id}'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: aContext.colors.primary),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Text(note.body, style: TextStyle(color: palette.inkPrimary)),
          ],
        ),
      ),
    );
  }
}
