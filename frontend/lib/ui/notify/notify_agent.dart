import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_router.dart';
import '../../core/device_tz.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../../providers/push_prov.dart';
import '../planner/planner_common.dart';
import '../stock/stock_format.dart';
import '../training/training_revision.dart';
import 'notify_format.dart';
import 'notify_state.dart';

const Duration _inboxPeriod = Duration(seconds: 60);
const Duration _resyncDelay = Duration(seconds: 3);

class NotifyAgent extends ConsumerStatefulWidget
{
  const NotifyAgent({super.key});

  @override
  ConsumerState<NotifyAgent> createState() => _NotifyAgentState();
}

class _NotifyAgentState extends ConsumerState<NotifyAgent> with WidgetsBindingObserver
{
  Timer? _inboxTimer;
  Timer? _resyncTimer;
  String? _syncedUser;
  String? _syncedLang;

  @override
  void initState()
  {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inboxTimer = Timer.periodic(_inboxPeriod, (_) => _refreshInbox());
    ref.read(pushPlatformProv).onOpen((aLink) => ref.read(routerProv).push(aLink));
  }

  @override
  void didChangeDependencies()
  {
    super.didChangeDependencies();
    final lang = Localizations.localeOf(context).languageCode;
    final userId = ref.read(authProv).user?.id;
    if (userId != null && (userId != _syncedUser || lang != _syncedLang))
    {
      _syncedUser = userId;
      _syncedLang = lang;
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncAll(userId, lang));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState aState)
  {
    if (aState == AppLifecycleState.resumed)
    {
      _refreshInbox();
      _schedulePlatformSync();
    }
  }

  @override
  void dispose()
  {
    WidgetsBinding.instance.removeObserver(this);
    _inboxTimer?.cancel();
    _resyncTimer?.cancel();
    super.dispose();
  }

  void _refreshInbox()
  {
    if (mounted && ref.read(authProv).isAuthenticated)
    {
      refreshNotices(ref);
    }
  }

  void _schedulePlatformSync()
  {
    _resyncTimer?.cancel();
    _resyncTimer = Timer(_resyncDelay, _syncPlatform);
  }

  Future<void> _syncPlatform() async
  {
    final userId = ref.read(authProv).user?.id;
    if (!mounted || userId == null)
    {
      return;
    }
    try
    {
      await ref.read(pushPlatformProv).sync(ref.read(apiProv), noticeTexts(), userId);
    }
    catch (_)
    {
      return;
    }
  }

  Future<void> _syncAll(String aUserId, String aLang) async
  {
    final api = ref.read(apiProv);
    try
    {
      final settings = await api.getNotifySettings();
      final tz = deviceTimeZone();
      if (settings.tz != tz || settings.lang != aLang)
      {
        await api.saveNotifySettings({'tz': tz, 'lang': aLang});
      }
    }
    catch (_)
    {
      _syncedUser = null;
    }
    await _syncPlatform();
  }

  @override
  Widget build(BuildContext aContext)
  {
    ref.listen<int>(plannerRevisionProv, (_, __) => _schedulePlatformSync());
    ref.listen<int>(stockRevisionProv, (_, __) => _schedulePlatformSync());
    ref.listen<int>(trainingRevisionProv, (_, __) => _schedulePlatformSync());
    return const SizedBox.shrink();
  }
}
