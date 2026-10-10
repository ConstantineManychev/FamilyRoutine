import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';

class FamGroupsGrid extends StatelessWidget
{
  final List<FamDto> fams;
  final VoidCallback onCreateFam;
  final ValueChanged<String> onSelectFam;
  final ValueChanged<String> onDeleteFam;
  final ValueChanged<String> onLeaveFam;

  const FamGroupsGrid({
    super.key,
    required this.fams,
    required this.onCreateFam,
    required this.onSelectFam,
    required this.onDeleteFam,
    required this.onLeaveFam,
  });

  @override
  Widget build(BuildContext aContext)
  {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        crossAxisSpacing: 24,
        mainAxisSpacing: 24,
        childAspectRatio: 1.5,
      ),
      itemCount: fams.length + 1,
      itemBuilder: (_, aIndex)
      {
        if (aIndex == fams.length)
        {
          return _FamActionCard(title: 'family.create_action'.tr(), icon: Icons.add, onTap: onCreateFam);
        }

        final fam = fams[aIndex];
        return _FamCard(
          fam: fam,
          onTap: () => onSelectFam(fam.id),
          onDelete: () => onDeleteFam(fam.id),
          onLeave: () => onLeaveFam(fam.id),
        );
      },
    );
  }
}

class _FamCard extends StatefulWidget
{
  final FamDto fam;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onLeave;

  const _FamCard({required this.fam, required this.onTap, required this.onDelete, required this.onLeave});

  @override
  State<_FamCard> createState() => _FamCardState();
}

class _FamCardState extends State<_FamCard>
{
  bool _isHovered = false;

  Future<void> _handleDelete() async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'family.delete_confirm_title'.tr(),
      aMessage: 'family.delete_confirm_desc'.tr(),
    );

    if (isConfirmed)
    {
      widget.onDelete();
    }
  }

  Future<void> _handleLeave() async
  {
    if (widget.fam.isOwner && widget.fam.memberCount > 1)
    {
      showInfoSnack(context, 'errors.OWNER_MUST_TRANSFER'.tr());
      return;
    }

    final descKey = widget.fam.memberCount == 1 ? 'family.leave_last_member_desc' : 'family.leave_confirm_desc';
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'family.leave_confirm_title'.tr(),
      aMessage: descKey.tr(),
    );

    if (isConfirmed)
    {
      widget.onLeave();
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Card(
        elevation: _isHovered ? 6 : 3,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          onTap: widget.onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    widget.fam.name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (widget.fam.isOwner)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Tooltip(
                    message: 'family.roles.owner'.tr(),
                    child: const Icon(AppIcons.crown, size: 18, color: Colors.amber),
                  ),
                ),
              Positioned(
                top: 4,
                right: 4,
                child: PopupMenuButton<String>(
                  tooltip: 'common.actions'.tr(),
                  icon: const Icon(AppIcons.moreVertical, size: 20),
                  onSelected: (aValue)
                  {
                    if (aValue == 'delete')
                    {
                      _handleDelete();
                    }
                    else if (aValue == 'leave')
                    {
                      _handleLeave();
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'leave',
                      child: ListTile(
                        leading: const Icon(AppIcons.doorOpen, color: Colors.redAccent),
                        title: Text('family.leave'.tr()),
                      ),
                    ),
                    if (widget.fam.isOwner)
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: const Icon(AppIcons.trash2, color: Colors.redAccent),
                          title: Text('family.delete'.tr()),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FamActionCard extends StatelessWidget
{
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _FamActionCard({required this.title, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: const Color(0x0D2196F3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.blue.shade200, width: 2),
      ),
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: Colors.blue.shade700),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(fontSize: 16, color: Colors.blue.shade700, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}
