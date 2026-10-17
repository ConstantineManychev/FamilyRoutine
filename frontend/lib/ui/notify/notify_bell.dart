import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../common/app_icons.dart';
import 'notify_format.dart';
import 'notify_state.dart';

const int _maxBadge = 99;

class NotifyBell extends ConsumerWidget
{
  const NotifyBell({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    final unread = aRef.watch(noticeInboxProv).valueOrNull?.unread ?? 0;
    final tooltip = unread > 0 ? 'notify.title_unread'.tr(args: ['$unread']) : 'notify.title'.tr();

    return IconButton(
      key: const ValueKey('notify.bell'),
      tooltip: tooltip,
      onPressed: () => aContext.push(notificationsPath),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text(unread > _maxBadge ? '$_maxBadge+' : '$unread'),
        child: Icon(unread > 0 ? AppIcons.bellRing : AppIcons.bell),
      ),
    );
  }
}
