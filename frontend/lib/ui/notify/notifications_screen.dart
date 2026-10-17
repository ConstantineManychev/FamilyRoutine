import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/push/push_platform.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'device_push_card.dart';
import 'notify_format.dart';
import 'notify_state.dart';

const String _settingsPath = '/app/settings';

class NotificationsScreen extends ConsumerStatefulWidget
{
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen>
{
  @override
  void initState()
  {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_)
    {
      if (mounted)
      {
        refreshNotices(ref);
      }
    });
  }

  Future<void> _markAll() async
  {
    try
    {
      await ref.read(apiProv).markNoticesRead(aIsAll: true);
      refreshNotices(ref);
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  Future<void> _open(AppNotice aNotice) async
  {
    if (!aNotice.isRead)
    {
      try
      {
        await ref.read(apiProv).markNoticesRead(aIds: [aNotice.id]);
        refreshNotices(ref);
      }
      catch (_)
      {
        refreshNotices(ref);
      }
    }
    if (mounted && isAppLink(aNotice.link))
    {
      context.push(aNotice.link);
    }
  }

  String _when(BuildContext aContext, DateTime aTs)
  {
    final locale = aContext.locale.toLanguageTag();
    final now = DateTime.now();
    final isToday = aTs.year == now.year && aTs.month == now.month && aTs.day == now.day;
    return isToday ? DateFormat.Hm(locale).format(aTs) : DateFormat.MMMd(locale).add_Hm().format(aTs);
  }

  Widget _tile(BuildContext aContext, AppNotice aNotice)
  {
    final palette = aContext.palette;
    final (title, body) = renderNotice(aNotice);
    return ListTile(
      key: ValueKey('notify.item.${aNotice.id}'),
      onTap: () => _open(aNotice),
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: aNotice.isRead ? palette.surfaceMuted : aContext.colors.primaryContainer,
        child: Icon(noticeIcon(aNotice.kind), size: 18, color: aNotice.isRead ? palette.inkMuted : aContext.colors.primary),
      ),
      title: Text(title, style: TextStyle(fontWeight: aNotice.isRead ? FontWeight.w500 : FontWeight.w700)),
      subtitle: Text(body, maxLines: 3, overflow: TextOverflow.ellipsis),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(_when(aContext, aNotice.createdTs), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
          if (!aNotice.isRead) ...[
            const SizedBox(height: 6),
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: aContext.colors.primary, shape: BoxShape.circle),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final inbox = ref.watch(noticeInboxProv);
    final data = inbox.valueOrNull;

    return ListPage(
      title: 'notify.title'.tr(),
      actions: [
        IconButton(
          key: const ValueKey('notify.read_all'),
          tooltip: 'notify.read_all'.tr(),
          onPressed: (data?.unread ?? 0) > 0 ? _markAll : null,
          icon: const Icon(AppIcons.checkCheck),
        ),
        IconButton(
          key: const ValueKey('notify.settings'),
          tooltip: 'notify.settings_tooltip'.tr(),
          onPressed: () => aContext.push(_settingsPath),
          icon: const Icon(AppIcons.settings),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: () async => refreshNotices(ref),
        child: ListView(
          padding: screenPadding(aContext),
          children: [
            const DevicePushCard(isHiddenWhenSettled: true),
            const SizedBox(height: 12),
            if (data == null && inbox.hasError)
              ErrorRetry(error: inbox.error!, onRetry: () => refreshNotices(ref))
            else if (data == null)
              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else if (data.items.isEmpty)
              BlockEmpty('notify.empty'.tr())
            else
              Card(
                margin: EdgeInsets.zero,
                semanticContainer: false,
                clipBehavior: Clip.antiAlias,
                child: Column(children: [for (final notice in data.items) _tile(aContext, notice)]),
              ),
          ],
        ),
      ),
    );
  }
}
