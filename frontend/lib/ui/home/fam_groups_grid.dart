import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';

class FamGroupsGrid extends StatelessWidget {
  final List<FamDto> fams;
  final VoidCallback onCreateFam;
  final Function(String) onSelectFam;
  final Function(String) onDeleteFam;
  final Function(String) onLeaveFam;

  const FamGroupsGrid({
    super.key,
    required this.fams,
    required this.onCreateFam,
    required this.onSelectFam,
    required this.onDeleteFam,
    required this.onLeaveFam,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(32),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 300,
        crossAxisSpacing: 24,
        mainAxisSpacing: 24,
        childAspectRatio: 1.5,
      ),
      itemCount: fams.length + 1,
      itemBuilder: (ctx, i) {
        if (i == fams.length) {
          return _FamActionCard(
            title: 'family.create_action'.tr(),
            icon: Icons.add,
            onTap: onCreateFam,
          );
        }
        return _FamCard(
          fam: fams[i],
          onTap: () => onSelectFam(fams[i].id),
          onDelete: () => onDeleteFam(fams[i].id),
          onLeave: () => onLeaveFam(fams[i].id),
        );
      },
    );
  }
}

class _FamCard extends StatefulWidget {
  final FamDto fam;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onLeave;

  const _FamCard({
    required this.fam,
    required this.onTap,
    required this.onDelete,
    required this.onLeave,
  });

  @override
  State<_FamCard> createState() => _FamCardState();
}

class _FamCardState extends State<_FamCard> {
  bool _isHovered = false;

  void _confirmAction(String titleKey, String descKey, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titleKey.tr()),
        content: Text(descKey.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('common.no'.tr()),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.of(ctx).pop();
              onConfirm();
            },
            child: Text('common.yes'.tr()),
          ),
        ],
      ),
    );
  }

  void _handleDelete() {
    _confirmAction('family.delete_confirm_title', 'family.delete_confirm_desc', widget.onDelete);
  }

  void _handleLeave() {
    final desc = widget.fam.memberCount == 1 ? 'family.leave_last_member_desc' : 'family.leave_confirm_desc';
    _confirmAction('family.leave_confirm_title', desc, widget.onLeave);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(16),
            child: Card(
              elevation: _isHovered ? 6 : 3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Center(
                child: Text(
                  widget.fam.name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          if (_isHovered)
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  if (widget.fam.role == 'admin')
                    IconButton(
                      icon: const Icon(LucideIcons.trash2, color: Colors.redAccent, size: 20),
                      tooltip: 'Удалить',
                      onPressed: _handleDelete,
                    ),
                  IconButton(
                    icon: const Icon(LucideIcons.doorOpen, color: Colors.redAccent, size: 20),
                    tooltip: 'Покинуть',
                    onPressed: _handleLeave,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FamActionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _FamActionCard({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Card(
        elevation: 0,
        color: Colors.blue.withOpacity(0.05),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.blue.shade200, width: 2, strokeAlign: BorderSide.strokeAlignInside),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: Colors.blue.shade700),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(fontSize: 16, color: Colors.blue.shade700, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}