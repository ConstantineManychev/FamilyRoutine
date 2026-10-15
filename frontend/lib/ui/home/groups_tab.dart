import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';

class GroupsActions
{
  final BuildContext context;
  final WidgetRef ref;

  const GroupsActions(this.context, this.ref);

  void create() => context.push('/app/families/new');

  void open(String aId) => context.push('/app/families/$aId');

  Future<void> joinByCode() async
  {
    final code = await showDialog<String>(context: context, builder: (_) => const _JoinCodeDialog());
    if (code == null || code.trim().isEmpty || !context.mounted)
    {
      return;
    }

    try
    {
      final famId = await ref.read(apiProv).acceptInvite(code.trim());
      ref.invalidate(famsProv);
      if (context.mounted)
      {
        showInfoSnack(context, 'family.joined'.tr());
        open(famId);
      }
    }
    catch (aError)
    {
      if (context.mounted)
      {
        showErrorSnack(context, aError);
      }
    }
  }

  Future<void> leave(FamDto aFam) async
  {
    if (aFam.isOwner && aFam.memberCount > 1)
    {
      showInfoSnack(context, 'errors.OWNER_MUST_TRANSFER'.tr());
      return;
    }
    final descKey = aFam.memberCount == 1 ? 'family.leave_last_member_desc' : 'family.leave_confirm_desc';
    final isConfirmed = await confirmAction(context, aTitle: 'family.leave_confirm_title'.tr(), aMessage: descKey.tr());
    if (isConfirmed)
    {
      await _run(() => ref.read(apiProv).leaveFam(aFam.id));
    }
  }

  Future<void> delete(FamDto aFam) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'family.delete_confirm_title'.tr(),
      aMessage: 'family.delete_confirm_desc'.tr(),
    );
    if (isConfirmed)
    {
      await _run(() => ref.read(apiProv).deleteFam(aFam.id));
    }
  }

  Future<void> _run(Future<void> Function() aAction) async
  {
    try
    {
      await aAction();
    }
    catch (aError)
    {
      if (context.mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    ref.invalidate(famsProv);
  }
}

class GroupsTab extends ConsumerStatefulWidget
{
  const GroupsTab({super.key});

  @override
  ConsumerState<GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends ConsumerState<GroupsTab> with AutomaticKeepAliveClientMixin
{
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext aContext)
  {
    super.build(aContext);
    aContext.locale;
    final actions = GroupsActions(aContext, ref);

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(famsProv),
      child: ListView(
        key: const PageStorageKey('home.groups'),
        padding: tabPadding(aContext),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: actions.create,
                icon: const Icon(AppIcons.plus, size: 18),
                label: Text('family.create_group'.tr()),
              ),
              OutlinedButton.icon(
                onPressed: actions.joinByCode,
                icon: const Icon(AppIcons.keyRound, size: 18),
                label: Text('family.join_by_code'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 16),
          GroupsBlock(actions: actions),
        ],
      ),
    );
  }
}

class GroupsBlock extends ConsumerWidget
{
  final GroupsActions actions;
  final bool isFramed;
  final String query;

  const GroupsBlock({super.key, required this.actions, this.isFramed = true, this.query = ''});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    final famsAsync = aRef.watch(famsProv);
    final content = famsAsync.when(
      data: (aFams)
      {
        final shown = aFams.where((aFam) => query.isEmpty || aFam.name.toLowerCase().contains(query)).toList();
        return shown.isEmpty
            ? BlockEmpty('family.no_groups'.tr())
            : Column(children: [for (final fam in shown) GroupTile(fam: fam, actions: actions)]);
      },
      loading: () => const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(famsProv)),
    );

    if (!isFramed)
    {
      return content;
    }
    return BlockCard(title: 'family.my_groups'.tr(), onAdd: actions.create, addTooltip: 'family.create_group'.tr(), child: content);
  }
}

class GroupTile extends StatelessWidget
{
  final FamDto fam;
  final GroupsActions actions;

  const GroupTile({super.key, required this.fam, required this.actions});

  @override
  Widget build(BuildContext aContext)
  {
    final role = fam.isOwner ? 'family.roles.owner'.tr() : 'family.roles.${fam.role.name}'.tr();

    return ListTile(
      onTap: () => actions.open(fam.id),
      leading: CircleAvatar(
        backgroundColor: aContext.colors.primaryContainer,
        foregroundColor: aContext.colors.onPrimaryContainer,
        child: Text(fam.name.isEmpty ? '?' : fam.name.characters.first.toUpperCase()),
      ),
      title: Text(fam.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text('${'family.member_count'.plural(fam.memberCount)} · $role'),
      trailing: PopupMenuButton<String>(
        tooltip: 'common.actions'.tr(),
        icon: const Icon(AppIcons.moreVertical, size: 20),
        onSelected: (aValue) => aValue == 'delete' ? actions.delete(fam) : actions.leave(fam),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'leave',
            child: ListTile(leading: Icon(AppIcons.doorOpen, color: aContext.palette.danger), title: Text('family.leave'.tr())),
          ),
          if (fam.isOwner)
            PopupMenuItem(
              value: 'delete',
              child: ListTile(leading: Icon(AppIcons.trash2, color: aContext.palette.danger), title: Text('family.delete'.tr())),
            ),
        ],
      ),
    );
  }
}

class _JoinCodeDialog extends StatefulWidget
{
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog>
{
  final _codeCtrl = TextEditingController();

  @override
  void dispose()
  {
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('family.join_by_code'.tr()),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('family.join_hint'.tr()),
          const SizedBox(height: 16),
          TextField(
            controller: _codeCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(20)],
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'XXXX-XXXX-XXXX'),
            onSubmitted: (aValue) => Navigator.of(aContext).pop(aValue),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        FilledButton(onPressed: () => Navigator.of(aContext).pop(_codeCtrl.text), child: Text('family.join'.tr())),
      ],
    );
  }
}
