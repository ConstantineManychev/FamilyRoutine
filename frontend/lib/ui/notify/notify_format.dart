import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';

import '../../core/push/push_platform.dart';
import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../stock/stock_format.dart';

const String notificationsPath = '/app/notifications';
const List<int> leadChoices = [0, 5, 10, 15, 30, 60, 120, 180, 1440];
const int _minutesPerHour = 60;

String leadLabel(int aMinutes)
{
  if (aMinutes == 0)
  {
    return 'notify.lead_now'.tr();
  }
  if (aMinutes % _minutesPerHour == 0)
  {
    return 'notify.lead_hours'.tr(args: ['${aMinutes ~/ _minutesPerHour}']);
  }
  return 'notify.lead_minutes'.tr(args: ['$aMinutes']);
}

IconData noticeIcon(NotifyKind aKind) => switch (aKind)
{
  NotifyKind.plan => AppIcons.calendarClock,
  NotifyKind.workout => AppIcons.dumbbell,
  NotifyKind.expiring => AppIcons.hourglass,
  NotifyKind.expired => AppIcons.trash2,
};

String _stockBody(NoticeContent aNotice)
{
  final lines = aNotice.lines;
  if (lines.isEmpty)
  {
    return aNotice.body;
  }
  final quantity = NumberFormat('#,##0.#');
  final text = lines.map((aLine) => '${aLine.title} ${quantity.format(aLine.qty)} ${measureLabel(aLine.measure)}').join(', ');
  final more = aNotice.more > 0 ? 'notify.more'.tr(args: ['${aNotice.more}']) : '';
  final familyName = aNotice.familyName;
  return '${familyName == null ? '' : '$familyName: '}$text$more';
}

(String, String) renderNotice(NoticeContent aNotice)
{
  final eventTitle = aNotice.eventTitle;
  final startTs = aNotice.startTs;
  final startsAt = startTs == null ? aNotice.body : 'notify.starts_at'.tr(args: [DateFormat.Hm().format(startTs)]);
  return switch (aNotice.kind)
  {
    NotifyKind.plan => (eventTitle ?? aNotice.title, startsAt),
    NotifyKind.workout => (eventTitle == null ? aNotice.title : 'notify.workout_title'.tr(args: [eventTitle]), startsAt),
    NotifyKind.expiring => (aNotice.isToday ? 'notify.expiring_today'.tr() : 'notify.expiring_tomorrow'.tr(), _stockBody(aNotice)),
    NotifyKind.expired => ('notify.expired_title'.tr(), _stockBody(aNotice)),
  };
}

NoticeTexts noticeTexts() => NoticeTexts(channelName: 'notify.channel'.tr(), render: renderNotice);
