import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';

final StateProvider<int> routineRevisionProv = StateProvider<int>((aRef) => 0);

extension RoutineStatusStyle on RoutineStatus
{
  Color get color => switch (this)
  {
    RoutineStatus.work => const Color(0xFF2A78D6),
    RoutineStatus.meal => const Color(0xFFEB6834),
    RoutineStatus.home => const Color(0xFF1BAF7A),
    RoutineStatus.transit => const Color(0xFFEDA100),
    RoutineStatus.leisure => const Color(0xFFE87BA4),
    RoutineStatus.gym => const Color(0xFF008300),
    RoutineStatus.sleep => const Color(0xFF6250D6),
    RoutineStatus.school => const Color(0xFFE34948),
    RoutineStatus.other => const Color(0xFF898781),
  };

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
        color: status.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 14, color: status.color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              caption == null ? status.label : '${status.label} · $caption',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
            ),
          ),
        ],
      ),
    );
  }
}
