import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/push/push_platform.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../../providers/push_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'notify_format.dart';

class DevicePushStatus
{
  final PushMode mode;
  final PushPermission permission;
  final bool isEnabled;
  final bool isServerReady;

  const DevicePushStatus({required this.mode, required this.permission, required this.isEnabled, required this.isServerReady});

  bool get canEnable => mode != PushMode.none && isServerReady && permission != PushPermission.denied && !isEnabled;
}

final AutoDisposeFutureProvider<DevicePushStatus> devicePushProv = FutureProvider.autoDispose<DevicePushStatus>((aRef) async
{
  final platform = aRef.read(pushPlatformProv);
  final userId = aRef.watch(authProv.select((aState) => aState.user?.id));
  final isServerReady = switch (platform.mode)
  {
    PushMode.web => await aRef.read(apiProv).getPushKey() != null,
    PushMode.local => true,
    PushMode.none => false,
  };
  return DevicePushStatus(
    mode: platform.mode,
    permission: await platform.permission(),
    isEnabled: userId != null && await platform.isEnabled(userId),
    isServerReady: isServerReady,
  );
});

class DevicePushCard extends ConsumerStatefulWidget
{
  final bool isHiddenWhenSettled;

  const DevicePushCard({super.key, this.isHiddenWhenSettled = false});

  @override
  ConsumerState<DevicePushCard> createState() => _DevicePushCardState();
}

class _DevicePushCardState extends ConsumerState<DevicePushCard>
{
  bool _isBusy = false;

  Future<void> _toggle(DevicePushStatus aStatus) async
  {
    final userId = ref.read(authProv).user?.id;
    if (userId == null)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      final platform = ref.read(pushPlatformProv);
      final api = ref.read(apiProv);
      if (aStatus.isEnabled)
      {
        await platform.disable(api);
      }
      else
      {
        final isOn = await platform.enable(api, noticeTexts(), userId);
        if (mounted)
        {
          showInfoSnack(context, isOn ? 'notify.device_enabled'.tr() : 'notify.device_failed'.tr());
        }
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
        ref.invalidate(devicePushProv);
      }
    }
  }

  String _statusText(DevicePushStatus aStatus)
  {
    if (aStatus.mode == PushMode.none)
    {
      return 'notify.device_unsupported'.tr();
    }
    if (!aStatus.isServerReady)
    {
      return 'notify.device_server_off'.tr();
    }
    if (aStatus.isEnabled)
    {
      return 'notify.device_on'.tr();
    }
    if (aStatus.permission == PushPermission.denied)
    {
      return 'notify.device_denied'.tr();
    }
    return 'notify.device_off'.tr();
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final status = ref.watch(devicePushProv).valueOrNull;
    if (status == null)
    {
      return const SizedBox.shrink();
    }
    final isActionable = status.isEnabled || status.canEnable;
    if (widget.isHiddenWhenSettled && !status.canEnable)
    {
      return const SizedBox.shrink();
    }

    return Container(
      key: const ValueKey('notify.device'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: palette.surfaceMuted, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(status.isEnabled ? AppIcons.bellRing : AppIcons.bellOff, size: 20, color: status.isEnabled ? palette.positive : palette.inkSecondary),
          const SizedBox(width: 10),
          Expanded(child: Text(_statusText(status), style: TextStyle(fontSize: 13, color: palette.inkPrimary))),
          if (isActionable) ...[
            const SizedBox(width: 8),
            status.isEnabled
                ? OutlinedButton(
                    key: const ValueKey('notify.device_toggle'),
                    onPressed: _isBusy ? null : () => _toggle(status),
                    child: Text('notify.device_disable'.tr()),
                  )
                : FilledButton(
                    key: const ValueKey('notify.device_toggle'),
                    onPressed: _isBusy ? null : () => _toggle(status),
                    child: Text('notify.device_enable'.tr()),
                  ),
          ],
        ],
      ),
    );
  }
}
