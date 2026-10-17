import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../../providers/push_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'device_push_card.dart';
import 'notify_format.dart';

class NotifySettingsSection extends ConsumerStatefulWidget
{
  const NotifySettingsSection({super.key});

  @override
  ConsumerState<NotifySettingsSection> createState() => _NotifySettingsSectionState();
}

class _NotifySettingsSectionState extends ConsumerState<NotifySettingsSection>
{
  NotifySettings? _settings;
  Object? _error;
  bool _isSaving = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    try
    {
      final settings = await ref.read(apiProv).getNotifySettings();
      if (mounted)
      {
        setState(() => _settings = settings);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  Future<void> _save(Map<String, Object?> aPatch) async
  {
    setState(() => _isSaving = true);
    try
    {
      final api = ref.read(apiProv);
      final saved = await api.saveNotifySettings(aPatch);
      if (!mounted)
      {
        return;
      }
      setState(() => _settings = saved);
      final userId = ref.read(authProv).user?.id;
      if (userId != null)
      {
        await ref.read(pushPlatformProv).sync(api, noticeTexts(), userId);
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
        setState(() => _isSaving = false);
      }
    }
  }

  Widget _toggle({required String aKey, required String aTitle, required String aHint, required bool aValue, required String aField})
  {
    return SwitchListTile(
      key: ValueKey('notify.$aKey'),
      contentPadding: EdgeInsets.zero,
      title: Text(aTitle),
      subtitle: Text(aHint, style: TextStyle(fontSize: 12, color: context.palette.inkMuted)),
      value: aValue,
      onChanged: _isSaving ? null : (aIsOn) => _save({aField: aIsOn}),
    );
  }

  Widget _lead({required String aKey, required int aValue, required bool aIsOn, required String aField})
  {
    final choices = {...leadChoices, aValue}.toList()..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.clock, size: 16, color: context.palette.inkSecondary),
              const SizedBox(width: 8),
              Text('notify.lead'.tr(), style: TextStyle(color: context.palette.inkSecondary)),
            ],
          ),
          SizedBox(
            width: 170,
            child: DropdownButtonFormField<int>(
              key: ValueKey('notify.$aKey'),
              initialValue: aValue,
              isExpanded: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: [for (final minutes in choices) DropdownMenuItem(value: minutes, child: Text(leadLabel(minutes)))],
              onChanged: !aIsOn || _isSaving
                  ? null
                  : (aMinutes)
                  {
                    if (aMinutes != null && aMinutes != aValue)
                    {
                      _save({aField: aMinutes});
                    }
                  },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final palette = aContext.palette;
    final settings = _settings;

    return Card(
      key: const ValueKey('notify.section'),
      margin: EdgeInsets.zero,
      semanticContainer: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'notify.settings_title'.tr(),
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: palette.inkPrimary),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('notify.open_list'),
                  onPressed: () => aContext.push(notificationsPath),
                  icon: const Icon(AppIcons.bell, size: 16),
                  label: Text('notify.open_list'.tr()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const DevicePushCard(),
            const SizedBox(height: 8),
            if (settings == null && _error != null)
              ErrorRetry(
                error: _error!,
                onRetry: ()
                {
                  setState(() => _error = null);
                  _load();
                },
              )
            else if (settings == null)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else ...[
              _toggle(
                aKey: 'is_plan',
                aTitle: 'notify.kind_plan'.tr(),
                aHint: 'notify.kind_plan_hint'.tr(),
                aValue: settings.isPlan,
                aField: 'is_plan',
              ),
              _lead(aKey: 'plan_lead', aValue: settings.planLeadMin, aIsOn: settings.isPlan, aField: 'plan_lead_min'),
              _toggle(
                aKey: 'is_workout',
                aTitle: 'notify.kind_workout'.tr(),
                aHint: 'notify.kind_workout_hint'.tr(),
                aValue: settings.isWorkout,
                aField: 'is_workout',
              ),
              _lead(aKey: 'workout_lead', aValue: settings.workoutLeadMin, aIsOn: settings.isWorkout, aField: 'workout_lead_min'),
              _toggle(
                aKey: 'is_expiring',
                aTitle: 'notify.kind_expiring'.tr(),
                aHint: 'notify.kind_expiring_hint'.tr(),
                aValue: settings.isExpiring,
                aField: 'is_expiring',
              ),
              _toggle(
                aKey: 'is_expired',
                aTitle: 'notify.kind_expired'.tr(),
                aHint: 'notify.kind_expired_hint'.tr(),
                aValue: settings.isExpired,
                aField: 'is_expired',
              ),
              const SizedBox(height: 4),
              Text('notify.tz_hint'.tr(args: [settings.tz]), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            ],
          ],
        ),
      ),
    );
  }
}
