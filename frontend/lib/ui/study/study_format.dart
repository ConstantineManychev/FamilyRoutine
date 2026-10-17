import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_theme.dart';
import '../routine/routine_style.dart';

final StateProvider<int> studyRevisionProv = StateProvider<int>((aRef) => 0);

final AutoDisposeFutureProvider<StudyTree> studyTreeProv = FutureProvider.autoDispose<StudyTree>((aRef)
{
  aRef.watch(studyRevisionProv);
  return aRef.read(apiProv).getStudyTree();
});

const String studyPath = '/app/study';

String topicPath(String aId) => '/app/study/$aId';

void notifyStudyChanged(WidgetRef aRef)
{
  aRef.read(studyRevisionProv.notifier).state++;
  aRef.read(routineRevisionProv.notifier).state++;
}

String studyNumber(BuildContext aContext, double aValue) =>
    NumberFormat('#,##0.#', aContext.locale.toLanguageTag()).format(aValue);

String unitLabel(StudyUnit aUnit) => 'study.unit_${aUnit.name}'.tr();

String amountLine(BuildContext aContext, double aDone, double aTarget, StudyUnit aUnit) =>
    'study.amount'.tr(args: [studyNumber(aContext, aDone), studyNumber(aContext, aTarget), 'study.unit_short_${aUnit.name}'.tr()]);

String progressLine(BuildContext aContext, StudyProgress aProgress)
{
  final percent = 'study.percent'.tr(args: [studyNumber(aContext, aProgress.percent)]);
  final done = aProgress.done;
  final target = aProgress.target;
  final unit = aProgress.unit;
  if (done == null || target == null || unit == null || unit == StudyUnit.percent)
  {
    return percent;
  }
  return '$percent · ${amountLine(aContext, done, target, unit)}';
}

String noteStamp(BuildContext aContext, DateTime aTs) =>
    '${DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(aTs)}, ${formatClock(aContext, aTs)}';

class StudyProgressBar extends StatelessWidget
{
  final StudyProgress progress;
  final double height;

  const StudyProgressBar({super.key, required this.progress, this.height = 6});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: LinearProgressIndicator(
        value: (progress.percent / 100).clamp(0, 1).toDouble(),
        minHeight: height,
        backgroundColor: palette.surfaceMuted,
        color: progress.isComplete ? palette.positive : aContext.colors.primary,
      ),
    );
  }
}
