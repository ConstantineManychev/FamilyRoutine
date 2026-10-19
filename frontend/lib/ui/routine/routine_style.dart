import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';

const int maxMarkPastDays = 31;
const int maxMarkFutureHours = 24;

final StateProvider<int> routineRevisionProv = StateProvider<int>((aRef) => 0);

extension RoutineStatusStyle on RoutineStatus
{
  Color colorOf(BuildContext aContext) => aContext.palette.seriesAt(index);

  IconData get icon => switch (this)
  {
    RoutineStatus.work => AppIcons.briefcase,
    RoutineStatus.meal => AppIcons.utensils,
    RoutineStatus.home => AppIcons.home,
    RoutineStatus.transit => AppIcons.bus,
    RoutineStatus.leisure => AppIcons.popcorn,
    RoutineStatus.gym => AppIcons.dumbbell,
    RoutineStatus.sleep => AppIcons.moon,
    RoutineStatus.school => AppIcons.graduationCap,
    RoutineStatus.other => AppIcons.circleDot,
  };

  String get label => 'routine.status_$name'.tr();
}

String formatClock(BuildContext aContext, DateTime aTs) => DateFormat.Hm(aContext.locale.toLanguageTag()).format(aTs);

String formatSpan(BuildContext aContext, StatusMarkDto aMark)
{
  final start = formatClock(aContext, aMark.startTs);
  final end = aMark.endTs;
  return end == null ? '$start – ${'routine.now'.tr()}' : '$start – ${formatClock(aContext, end)}';
}

String formatDuration(Duration aDuration)
{
  final hours = aDuration.inHours;
  final minutes = aDuration.inMinutes.remainder(60);
  if (hours == 0)
  {
    return 'routine.minutes'.tr(args: ['$minutes']);
  }
  if (minutes == 0)
  {
    return 'routine.hours'.tr(args: ['$hours']);
  }
  return 'routine.hours_minutes'.tr(args: ['$hours', minutes.toString().padLeft(2, '0')]);
}

class StatusBadge extends StatelessWidget
{
  final RoutineStatus status;
  final String? caption;

  const StatusBadge({super.key, required this.status, this.caption});

  @override
  Widget build(BuildContext aContext)
  {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: status.colorOf(aContext).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 14, color: status.colorOf(aContext)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              caption == null ? status.label : '${status.label} · $caption',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: aContext.palette.inkPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
