import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../settings/ai_settings_section.dart';
import '../settings/app_settings_section.dart';
import '../training/person_training_card.dart';
import 'body_entry_editor.dart';
import 'metric_format.dart';
import '../common/app_theme.dart';

const double _contentMaxWidth = 960;
const double _tileWidth = 200;
const double _tileSpacing = 12;
const int _minTileColumns = 2;

String personPath(String aPersonId, bool aIsSelf) => aIsSelf ? '/app/profile' : '/app/people/$aPersonId';

class ProfileScreen extends ConsumerStatefulWidget
{
  final String? personId;

  const ProfileScreen({super.key, this.personId});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
{
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _currentPwdCtrl = TextEditingController();
  final _newPwdCtrl = TextEditingController();
  final _repeatPwdCtrl = TextEditingController();
  PersonProfile? _profile;
  Object? _loadError;
  DateTime? _birthDate;
  Sex? _sex;
  ActivityLevel? _activity;
  bool _isBusy = false;
  String? _passwordError;

  String? get _personId => widget.personId ?? ref.read(sessionUserIdProv);

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ProfileScreen aOld)
  {
    super.didUpdateWidget(aOld);
    if (aOld.personId != widget.personId)
    {
      setState(() => _profile = null);
      _load();
    }
  }

  @override
  void dispose()
  {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _currentPwdCtrl.dispose();
    _newPwdCtrl.dispose();
    _repeatPwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    final personId = _personId;
    if (personId == null)
    {
      return;
    }
    setState(() => _loadError = null);
    try
    {
      _apply(await ref.read(apiProv).getPerson(personId));
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
  }

  void _apply(PersonProfile aProfile)
  {
    if (!mounted)
    {
      return;
    }
    setState(()
    {
      _profile = aProfile;
      _firstNameCtrl.text = aProfile.firstName;
      _lastNameCtrl.text = aProfile.lastName;
      _birthDate = aProfile.birthDate;
      _sex = aProfile.sex;
      _activity = aProfile.activity;
    });
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    setState(() => _isBusy = true);
    try
    {
      await aAction();
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
      }
    }
  }

  Future<void> _savePersonal() async
  {
    final profile = _profile;
    final birthDate = _birthDate;
    if (profile == null || birthDate == null)
    {
      return;
    }
    await _run(() async
    {
      final updated = await ref.read(apiProv).updatePerson(
            profile.id,
            aFirstName: _firstNameCtrl.text.trim(),
            aLastName: _lastNameCtrl.text.trim(),
            aBirthDate: birthDate,
            aSex: _sex,
            aActivity: _activity,
          );
      _apply(updated);
      if (updated.isSelf)
      {
        await ref.read(authProv.notifier).refreshUser();
      }
      ref.invalidate(famsProv);
      if (mounted)
      {
        showInfoSnack(context, 'profile.saved'.tr());
      }
    });
  }

  Future<void> _changePassword() async
  {
    final current = _currentPwdCtrl.text;
    final next = _newPwdCtrl.text;
    final error = next.isEmpty || current.isEmpty
        ? 'profile.pwd_required'.tr()
        : next != _repeatPwdCtrl.text
            ? 'profile.pwd_mismatch'.tr()
            : null;
    setState(() => _passwordError = error);
    if (error != null)
    {
      return;
    }

    await _run(() async
    {
      await ref.read(apiProv).changePassword(current, next);
      _currentPwdCtrl.clear();
      _newPwdCtrl.clear();
      _repeatPwdCtrl.clear();
      if (mounted)
      {
        showInfoSnack(context, 'profile.pwd_changed'.tr());
      }
    });
  }

  Future<void> _saveSharing(ProfileSharing aUpdated) async
  {
    final profile = _profile;
    if (profile == null)
    {
      return;
    }
    await _run(() async
    {
      await ref.read(apiProv).setProfileSharing(profile.id, aUpdated);
      _apply(await ref.read(apiProv).getPerson(profile.id));
    });
  }

  Future<void> _addEntry() async
  {
    final profile = _profile;
    if (profile == null)
    {
      return;
    }
    final saved = await showBodyEntryEditor(context, aPersonId: profile.id, aPersonName: profile.fullName, aLatest: profile.latest);
    if (saved != null)
    {
      await _load();
      if (mounted)
      {
        showInfoSnack(context, 'metrics.saved'.tr());
      }
    }
  }

  Future<void> _pickBirthDate() async
  {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null)
    {
      setState(() => _birthDate = picked);
    }
  }

  void _openHistory(BodyMetric aMetric)
  {
    final profile = _profile;
    if (profile != null)
    {
      context.push('/app/people/${profile.id}/metrics/${aMetric.wire}');
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final profile = _profile;
    if (profile == null)
    {
      return _loadError != null
          ? ErrorRetry(error: _loadError!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: screenPadding(aContext),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(aContext, profile),
                const SizedBox(height: 24),
                _buildMetrics(aContext, profile),
                if (!profile.isSelf && profile.isTrainingVisible) ...[
                  const SizedBox(height: 24),
                  PersonTrainingCard(personId: profile.id),
                ],
                if (profile.canEdit) ...[
                  const SizedBox(height: 24),
                  _buildPersonal(aContext, profile),
                ],
                if (profile.canEdit && profile.sharing.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  _buildSharing(profile),
                ],
                if (profile.isSelf) ...[
                  const SizedBox(height: 24),
                  _buildPassword(),
                  const SizedBox(height: 24),
                  const AppSettingsSection(),
                  const SizedBox(height: 24),
                  const AiSettingsSection(),
                ],
                if (_isBusy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(List<Widget> aChildren)
  {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.palette.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: aChildren),
      ),
    );
  }

  Widget _sectionTitle(String aText) => Text(aText, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold));

  Widget _buildHeader(BuildContext aContext, PersonProfile aProfile)
  {
    final details = [
      if (aProfile.age != null) 'profile.years'.plural(aProfile.age!),
      if (aProfile.sex != null) 'profile.sex_${aProfile.sex!.name}'.tr(),
      if (aProfile.email != null) aProfile.email!,
    ];
    final initials = [aProfile.firstName, aProfile.lastName].where((aPart) => aPart.isNotEmpty).map((aPart) => aPart[0]).join().toUpperCase();

    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: context.colors.primary,
              child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            const SizedBox(width: 16),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(aProfile.fullName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  if (details.isNotEmpty) Text(details.join(' · '), style: TextStyle(color: context.palette.inkSecondary)),
                  if (aProfile.isManaged)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(AppIcons.user, size: 14),
                        label: Text('profile.child_badge'.tr()),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (aProfile.canEdit)
          FilledButton.icon(
            onPressed: _isBusy ? null : _addEntry,
            icon: const Icon(AppIcons.plus, size: 18),
            label: Text('metrics.add_entry'.tr()),
          ),
      ],
    );
  }

  Widget _buildMetrics(BuildContext aContext, PersonProfile aProfile)
  {
    if (aProfile.visibleGroups.isEmpty)
    {
      return Text('metrics.hidden'.tr(), style: TextStyle(color: context.palette.inkSecondary));
    }

    final groups = aProfile.visibleGroups.where((aGroup) => aProfile.canEdit || aProfile.latest.any((aValue) => aValue.metric.group == aGroup));
    if (aProfile.latest.isEmpty)
    {
      return _card([
        Text('metrics.empty'.tr(), style: TextStyle(color: context.palette.inkSecondary)),
      ]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in groups) ...[
          _sectionTitle(metricGroupName(group)),
          const SizedBox(height: 12),
          _buildGroupTiles(aContext, aProfile, group),
          const SizedBox(height: 20),
        ],
      ],
    );
  }

  Widget _buildGroupTiles(BuildContext aContext, PersonProfile aProfile, MetricGroup aGroup)
  {
    final values = BodyMetric.ofGroup(aGroup).map(aProfile.latestOf).whereType<MetricValue>().toList();
    if (values.isEmpty)
    {
      return Text('metrics.group_empty'.tr(), style: TextStyle(color: context.palette.inkMuted));
    }

    return LayoutBuilder(
      builder: (_, aConstraints)
      {
        final columns = math.max(_minTileColumns, (aConstraints.maxWidth / _tileWidth).floor());
        final width = (aConstraints.maxWidth - _tileSpacing * (columns - 1)) / columns;
        return Wrap(
          spacing: _tileSpacing,
          runSpacing: _tileSpacing,
          children: [for (final value in values) _buildTile(aContext, value, width.clamp(0.0, _tileWidth))],
        );
      },
    );
  }

  Widget _buildTile(BuildContext aContext, MetricValue aValue, double aWidth)
  {
    final delta = aValue.delta;

    return SizedBox(
      width: aWidth,
      child: Material(
        color: context.colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.palette.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openHistory(aValue.metric),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(metricName(aValue.metric), style: TextStyle(color: context.palette.inkSecondary, fontSize: 13)),
                const SizedBox(height: 4),
                Text(
                  formatMetric(aContext, aValue.metric, aValue.value),
                  style: TextStyle(color: context.palette.inkPrimary, fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(formatMeasuredDate(aContext, aValue.measuredTs), style: TextStyle(color: context.palette.inkMuted, fontSize: 12)),
                if (delta != null && aValue.prevTs != null)
                  Text(
                    'metrics.delta_since'.tr(args: [
                      formatMetric(aContext, aValue.metric, delta, aIsSigned: true),
                      formatMeasuredDate(aContext, aValue.prevTs!),
                    ]),
                    style: TextStyle(color: context.palette.inkSecondary, fontSize: 12),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPersonal(BuildContext aContext, PersonProfile aProfile)
  {
    final birthDate = _birthDate;

    return _card([
      _sectionTitle('profile.personal'.tr()),
      const SizedBox(height: 16),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: 260,
            child: TextField(
              controller: _firstNameCtrl,
              inputFormatters: [LengthLimitingTextInputFormatter(100)],
              decoration: InputDecoration(labelText: 'profile.first_name'.tr(), border: const OutlineInputBorder(), isDense: true),
            ),
          ),
          SizedBox(
            width: 260,
            child: TextField(
              controller: _lastNameCtrl,
              inputFormatters: [LengthLimitingTextInputFormatter(100)],
              decoration: InputDecoration(labelText: 'profile.last_name'.tr(), border: const OutlineInputBorder(), isDense: true),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _pickBirthDate,
            icon: const Icon(AppIcons.calendar, size: 18),
            label: Text(
              birthDate == null
                  ? 'profile.birth_date'.tr()
                  : '${'profile.birth_date'.tr()}: ${DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(birthDate)}',
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text('profile.sex'.tr(), style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<Sex>(
          emptySelectionAllowed: true,
          segments: [
            ButtonSegment(value: Sex.female, label: Text('profile.sex_female'.tr())),
            ButtonSegment(value: Sex.male, label: Text('profile.sex_male'.tr())),
          ],
          selected: {if (_sex != null) _sex!},
          onSelectionChanged: (aSelected) => setState(() => _sex = aSelected.firstOrNull),
        ),
      ),
      const SizedBox(height: 4),
      Text('profile.sex_hint'.tr(), style: TextStyle(color: context.palette.inkMuted, fontSize: 12)),
      const SizedBox(height: 16),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: DropdownButtonFormField<ActivityLevel?>(
          key: ValueKey('activity-${aProfile.id}-${aProfile.activity?.wire}'),
          initialValue: _activity,
          isExpanded: true,
          decoration: InputDecoration(labelText: 'profile.activity'.tr(), border: const OutlineInputBorder(), isDense: true),
          items: [
            DropdownMenuItem<ActivityLevel?>(value: null, child: Text('profile.activity_unset'.tr())),
            for (final level in ActivityLevel.values)
              DropdownMenuItem<ActivityLevel?>(
                value: level,
                child: Text('profile.activity_${level.wire}'.tr(), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (aLevel) => setState(() => _activity = aLevel),
        ),
      ),
      const SizedBox(height: 4),
      Text('profile.activity_hint'.tr(), style: TextStyle(color: context.palette.inkMuted, fontSize: 12)),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(onPressed: _isBusy ? null : _savePersonal, child: Text('common.save'.tr())),
      ),
    ]);
  }

  Widget _buildSharing(PersonProfile aProfile)
  {
    return _card([
      _sectionTitle('profile.sharing_title'.tr()),
      const SizedBox(height: 4),
      Text(
        aProfile.isSelf ? 'profile.sharing_hint'.tr() : 'profile.sharing_hint_child'.tr(),
        style: TextStyle(color: context.palette.inkSecondary),
      ),
      for (final sharing in aProfile.sharing) ...[
        const SizedBox(height: 12),
        Text(sharing.familyName, style: const TextStyle(fontWeight: FontWeight.w600)),
        for (final group in MetricGroup.values)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(metricGroupName(group)),
            value: sharing.isShared(group),
            onChanged: _isBusy ? null : (aValue) => _saveSharing(sharing.withGroup(group, aValue)),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text('profile.share_training'.tr()),
          value: sharing.isTrainingShared,
          onChanged: _isBusy ? null : (aValue) => _saveSharing(sharing.withTraining(aValue)),
        ),
      ],
    ]);
  }

  Widget _buildPassword()
  {
    Widget field(TextEditingController aCtrl, String aLabel) => SizedBox(
          width: 260,
          child: TextField(
            controller: aCtrl,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            inputFormatters: [LengthLimitingTextInputFormatter(128)],
            decoration: InputDecoration(labelText: aLabel, border: const OutlineInputBorder(), isDense: true),
          ),
        );

    return _card([
      _sectionTitle('profile.password'.tr()),
      const SizedBox(height: 4),
      Text('profile.pwd_hint'.tr(), style: TextStyle(color: context.palette.inkSecondary)),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          field(_currentPwdCtrl, 'profile.pwd_current'.tr()),
          field(_newPwdCtrl, 'profile.pwd_new'.tr()),
          field(_repeatPwdCtrl, 'profile.pwd_repeat'.tr()),
          FilledButton(onPressed: _isBusy ? null : _changePassword, child: Text('profile.pwd_change'.tr())),
        ],
      ),
      if (_passwordError != null) ...[
        const SizedBox(height: 8),
        Text(_passwordError!, style: TextStyle(color: context.palette.danger)),
      ],
    ]);
  }
}
