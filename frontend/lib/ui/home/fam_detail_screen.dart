import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';

class FamDetailScreen extends ConsumerStatefulWidget
{
  final String? famId;

  const FamDetailScreen({super.key, this.famId});

  @override
  ConsumerState<FamDetailScreen> createState() => _FamDetailScreenState();
}

class _FamDetailScreenState extends ConsumerState<FamDetailScreen>
{
  final _nameCtrl = TextEditingController();

  FamDetailDto? _famData;
  List<FamInviteDto> _invites = const [];
  Object? _loadError;
  bool _isLoading = false;
  bool _isSaving = false;

  bool get _isEdit => widget.famId != null;
  bool get _isAdmin => !_isEdit || (_famData?.isAdmin ?? false);

  @override
  void initState()
  {
    super.initState();
    if (_isEdit)
    {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant FamDetailScreen aOldWidget)
  {
    super.didUpdateWidget(aOldWidget);
    if (aOldWidget.famId != widget.famId && _isEdit)
    {
      _load();
    }
  }

  @override
  void dispose()
  {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    setState(()
    {
      _isLoading = true;
      _loadError = null;
    });

    try
    {
      final api = ref.read(apiProv);
      final fam = await api.getFamDetails(widget.famId!);
      final invites = fam.isAdmin ? await api.getFamInvites(fam.id) : const <FamInviteDto>[];

      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _famData = fam;
        _invites = invites;
        _nameCtrl.text = fam.name;
      });
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _runAction(Future<void> Function() aAction, {bool aIsReloadNeeded = true}) async
  {
    setState(() => _isSaving = true);

    try
    {
      await aAction();
      if (aIsReloadNeeded && _isEdit)
      {
        await _load();
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

  Future<void> _save() async
  {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty)
    {
      showInfoSnack(context, 'validation.required'.tr());
      return;
    }

    await _runAction(() async
    {
      final api = ref.read(apiProv);

      if (!_isEdit)
      {
        final created = await api.createFam(name);
        ref.invalidate(famsProv);
        if (mounted)
        {
          context.go('/app/families/${created.id}');
        }
        return;
      }

      await api.renameFam(widget.famId!, name);
      ref.invalidate(famsProv);
      if (mounted)
      {
        showInfoSnack(context, 'common.saved'.tr());
      }
    }, aIsReloadNeeded: false);
  }

  Future<void> _updateRole(FamMemberDto aMember, MemberRole aRole) async
  {
    await _runAction(() => ref.read(apiProv).updateMemberRole(widget.famId!, aMember.id, aRole));
  }

  Future<void> _removeMember(FamMemberDto aMember) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'family.remove_member'.tr(),
      aMessage: 'family.remove_member_confirm'.tr(namedArgs: {'name': '${aMember.fName} ${aMember.lName}'}),
    );

    if (isConfirmed)
    {
      await _runAction(() => ref.read(apiProv).removeMember(widget.famId!, aMember.id));
      ref.invalidate(famsProv);
    }
  }

  Future<void> _transferOwnership(FamMemberDto aMember) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'family.transfer_owner'.tr(),
      aMessage: 'family.transfer_owner_confirm'.tr(namedArgs: {'name': '${aMember.fName} ${aMember.lName}'}),
    );

    if (!isConfirmed)
    {
      return;
    }

    await _runAction(() async
    {
      await ref.read(apiProv).transferOwnership(widget.famId!, aMember.id);
      ref.invalidate(famsProv);
      if (mounted)
      {
        showInfoSnack(context, 'family.transfer_owner_done'.tr());
      }
    });
  }

  Future<void> _createInvite() async
  {
    final isOwner = _famData?.isOwner ?? false;
    final draft = await showDialog<_InviteDraft>(
      context: context,
      builder: (_) => _InviteDialog(isRoleSelectable: isOwner),
    );
    if (draft == null || !mounted)
    {
      return;
    }

    CreatedInviteDto? created;
    await _runAction(() async
    {
      created = await ref.read(apiProv).createInvite(widget.famId!, draft.role, draft.label);
    });

    final invite = created;
    if (invite != null && mounted)
    {
      await showDialog<void>(context: context, builder: (_) => _InviteCodeDialog(invite: invite));
    }
  }

  Future<void> _setRoutineSharing(bool aIsShared) async
  {
    await _runAction(() => ref.read(apiProv).setRoutineSharing(widget.famId!, aIsShared));
  }

  Future<void> _revokeInvite(FamInviteDto aInvite) async
  {
    await _runAction(() => ref.read(apiProv).revokeInvite(widget.famId!, aInvite.id));
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    if (_isEdit && _famData == null)
    {
      return _loadError != null
          ? ErrorRetry(error: _loadError!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }

    final currUserId = ref.watch(sessionUserIdProv);

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(
          title: _isEdit ? 'family.manage_group'.tr() : 'family.create_group'.tr(),
          actions: [
            if (_isAdmin)
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _save,
                icon: _isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(AppIcons.save, size: 18),
                label: Text(_isEdit ? 'common.save'.tr() : 'family.create_action'.tr()),
              ),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _nameCtrl,
          enabled: _isAdmin,
          inputFormatters: [LengthLimitingTextInputFormatter(100)],
          decoration: InputDecoration(labelText: 'family.group_name'.tr(), border: const OutlineInputBorder()),
        ),
        if (!_isEdit) ...[
          const SizedBox(height: 16),
          Text('family.create_hint'.tr(), style: const TextStyle(color: Colors.grey)),
        ],
        if (_isEdit) ...[
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: Color(0xFFE5E7EB)),
            ),
            child: SwitchListTile(
              secondary: const Icon(AppIcons.calendarClock),
              title: Text('routine.share_title'.tr()),
              subtitle: Text('routine.share_hint'.tr()),
              value: _famData?.isRoutineShared ?? true,
              onChanged: _isSaving ? null : _setRoutineSharing,
            ),
          ),
          const SizedBox(height: 32),
          Text('family.members'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _buildMembers(currUserId),
          if (_isAdmin) ...[
            const SizedBox(height: 32),
            _buildInvites(),
          ],
        ],
        if (_isLoading) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
      ],
    );
  }

  Widget _buildMembers(String? aCurrUserId)
  {
    final fam = _famData;
    final members = fam?.members ?? const <FamMemberDto>[];

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final member in members)
            ListTile(
              leading: CircleAvatar(child: Text(member.fName.isNotEmpty ? member.fName[0] : '?')),
              title: Text('${member.fName} ${member.lName}'),
              subtitle: Row(
                children: [
                  if (member.isOwner) ...[
                    const Icon(AppIcons.crown, size: 14, color: Colors.amber),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    member.isOwner ? 'family.roles.owner'.tr() : 'family.roles.${member.role.name}'.tr(),
                    style: TextStyle(color: member.isAdmin ? Colors.blue : Colors.grey),
                  ),
                ],
              ),
              trailing: fam != null && member.id != aCurrUserId ? _buildMemberMenu(fam, member) : null,
            ),
        ],
      ),
    );
  }

  Widget? _buildMemberMenu(FamDetailDto aFam, FamMemberDto aMember)
  {
    final isRoleEditable = aFam.isOwner && !aMember.isOwner;
    final isRemovable = aFam.canRemove(aMember);

    if (!isRoleEditable && !isRemovable)
    {
      return null;
    }

    return PopupMenuButton<String>(
      tooltip: 'common.actions'.tr(),
      enabled: !_isSaving,
      onSelected: (aValue)
      {
        switch (aValue)
        {
          case 'admin':
            _updateRole(aMember, MemberRole.admin);
          case 'standard':
            _updateRole(aMember, MemberRole.standard);
          case 'transfer':
            _transferOwnership(aMember);
          case 'remove':
            _removeMember(aMember);
        }
      },
      itemBuilder: (_) => [
        if (isRoleEditable && aMember.role != MemberRole.admin)
          PopupMenuItem(value: 'admin', child: Text('family.make_admin'.tr())),
        if (isRoleEditable && aMember.role != MemberRole.standard)
          PopupMenuItem(value: 'standard', child: Text('family.make_standard'.tr())),
        if (isRoleEditable)
          PopupMenuItem(value: 'transfer', child: Text('family.transfer_owner'.tr())),
        if (isRemovable)
          PopupMenuItem(
            value: 'remove',
            child: Text('family.remove_member'.tr(), style: const TextStyle(color: Colors.red)),
          ),
      ],
    );
  }

  Widget _buildInvites()
  {
    final dateFormat = DateFormat.yMMMd(context.locale.toLanguageTag());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ScreenHeader(
          title: 'family.invites'.tr(),
          actions: [
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _createInvite,
              icon: const Icon(AppIcons.userPlus, size: 18),
              label: Text('family.invite_create'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('family.invite_hint'.tr(), style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 12),
        if (_invites.isEmpty)
          Text('family.no_invites'.tr(), style: const TextStyle(fontStyle: FontStyle.italic))
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final invite in _invites)
                  ListTile(
                    leading: const Icon(AppIcons.ticket),
                    title: Text(invite.label?.isNotEmpty == true ? invite.label! : 'family.invite_unnamed'.tr()),
                    subtitle: Text(
                      '${'family.roles.${invite.role.name}'.tr()} · '
                      '${'family.invite_expires'.tr(namedArgs: {'date': dateFormat.format(invite.expiresTs)})}',
                    ),
                    trailing: IconButton(
                      tooltip: 'family.invite_revoke'.tr(),
                      icon: const Icon(AppIcons.x, color: Colors.red),
                      onPressed: _isSaving ? null : () => _revokeInvite(invite),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _InviteDraft
{
  final MemberRole role;
  final String? label;

  const _InviteDraft(this.role, this.label);
}

class _InviteDialog extends StatefulWidget
{
  final bool isRoleSelectable;

  const _InviteDialog({required this.isRoleSelectable});

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog>
{
  final _labelCtrl = TextEditingController();
  MemberRole _role = MemberRole.standard;

  @override
  void dispose()
  {
    _labelCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('family.invite_create'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _labelCtrl,
            inputFormatters: [LengthLimitingTextInputFormatter(100)],
            decoration: InputDecoration(
              labelText: 'family.invite_label'.tr(),
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.isRoleSelectable) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<MemberRole>(
            initialValue: _role,
            decoration: InputDecoration(labelText: 'family.role'.tr(), border: const OutlineInputBorder()),
            items: MemberRole.values
                .map((aRole) => DropdownMenuItem(value: aRole, child: Text('family.roles.${aRole.name}'.tr())))
                .toList(),
            onChanged: (aRole) => setState(() => _role = aRole ?? MemberRole.standard),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: ()
          {
            final label = _labelCtrl.text.trim();
            Navigator.of(aContext).pop(_InviteDraft(_role, label.isEmpty ? null : label));
          },
          child: Text('family.invite_generate'.tr()),
        ),
      ],
    );
  }
}

class _InviteCodeDialog extends StatelessWidget
{
  final CreatedInviteDto invite;

  const _InviteCodeDialog({required this.invite});

  @override
  Widget build(BuildContext aContext)
  {
    final expires = DateFormat.yMMMd(aContext.locale.toLanguageTag()).add_Hm().format(invite.expiresTs);

    return AlertDialog(
      title: Text('family.invite_code_title'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('family.invite_code_desc'.tr()),
          const SizedBox(height: 16),
          Text(
            invite.code,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 2, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 8),
          Text('family.invite_expires'.tr(namedArgs: {'date': expires}), style: const TextStyle(color: Colors.grey)),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () async
          {
            await Clipboard.setData(ClipboardData(text: invite.code));
            if (aContext.mounted)
            {
              showInfoSnack(aContext, 'common.copied'.tr());
            }
          },
          icon: const Icon(AppIcons.copy, size: 18),
          label: Text('common.copy'.tr()),
        ),
        ElevatedButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.ok'.tr())),
      ],
    );
  }
}
