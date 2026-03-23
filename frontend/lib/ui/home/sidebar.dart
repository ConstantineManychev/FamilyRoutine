import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/auth_provider.dart';

class Sidebar extends ConsumerStatefulWidget {
  final bool isExpanded;
  final VoidCallback onToggle;
  final String fName;
  final String lName;
  final List<FamDto> families;

  const Sidebar({
    super.key,
    required this.isExpanded,
    required this.onToggle,
    required this.fName,
    required this.lName,
    required this.families,
  });

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar> {
  bool _isDictExpanded = false;

  String get _initials {
    if (widget.fName.isNotEmpty && widget.lName.isNotEmpty) {
      return '${widget.fName[0]}${widget.lName[0]}'.toUpperCase();
    }
    return widget.fName.isNotEmpty ? widget.fName[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      width: widget.isExpanded ? 256.0 : 80.0,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: _buildNavigationList(),
          ),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildNavigationList() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 12.0),
      children: [
        _buildNavItem(LucideIcons.home, 'sidebar.routine'.tr()),
        _buildNavItem(LucideIcons.settings, 'sidebar.settings'.tr()),
        _buildNavItem(LucideIcons.calendarDays, 'sidebar.calendar'.tr()),
        _buildNavItem(LucideIcons.barChart, 'sidebar.hierarchy'.tr()),
        if (widget.isExpanded && widget.families.isNotEmpty) ...[
          const SizedBox(height: 24.0),
          _buildSectionTitle('sidebar.families'.tr()),
          _buildHierarchyList(LucideIcons.fileText, 'sidebar.hierarchy'.tr(), widget.families),
        ],
        if (widget.isExpanded) ...[
          const SizedBox(height: 24.0),
          _buildSectionTitle('sidebar.references'.tr()),
          _buildExpandableDict(),
        ],
      ],
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 96.0,
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: Row(
        mainAxisAlignment: widget.isExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          _buildAvatar(),
          if (widget.isExpanded) ...[
            const SizedBox(width: 16.0),
            _buildUserInfo(),
          ]
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return GestureDetector(
      onTap: widget.onToggle,
      child: Container(
        width: 48.0,
        height: 48.0,
        decoration: const BoxDecoration(
          color: Color(0xFF2563EB),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            _initials,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 18.0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserInfo() {
    return Expanded(
      child: Text(
        '${widget.fName} ${widget.lName}',
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14.0,
          color: Color(0xFF1F2937),
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: () {},
        child: Container(
          height: 48.0,
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            mainAxisAlignment: widget.isExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              Icon(icon, size: 24.0, color: const Color(0xFF4B5563)),
              if (widget.isExpanded) ...[
                const SizedBox(width: 16.0),
                _buildNavLabel(label),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavLabel(String label) {
    return Expanded(
      child: Text(
        label,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 16.0,
          color: Color(0xFF374151),
        ),
        maxLines: 1,
        overflow: TextOverflow.clip,
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 12.0, bottom: 8.0),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 10.0,
          fontWeight: FontWeight.bold,
          color: Color(0xFF9CA3AF),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildHierarchyList(IconData icon, String label, List<FamDto> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHierarchyHeader(icon, label),
        _buildHierarchyItems(items),
      ],
    );
  }

  Widget _buildHierarchyHeader(IconData icon, String label) {
    return Container(
      height: 40.0,
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        children: [
          Icon(icon, size: 20.0, color: const Color(0xFF4B5563)),
          const SizedBox(width: 12.0),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 16.0,
                color: Color(0xFF4B5563),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHierarchyItems(List<FamDto> items) {
    return Padding(
      padding: const EdgeInsets.only(left: 32.0, top: 4.0),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Color(0xFFF3F4F6), width: 2.0)),
        ),
        child: Column(
          children: items.map((item) => _buildSubItem(item.name)).toList(),
        ),
      ),
    );
  }

  Widget _buildExpandableDict() {
    return Column(
      children: [
        _buildDictToggle(),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _isDictExpanded ? _buildDictContent() : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildDictToggle() {
    return InkWell(
      onTap: () => setState(() => _isDictExpanded = !_isDictExpanded),
      child: Container(
        height: 40.0,
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('sidebar.dictionaries'.tr()),
            Icon(
              _isDictExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              size: 18.0,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDictContent() {
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, top: 8.0),
      child: Column(
        children: [
          _buildSubItem('sidebar.task_groups'.tr()),
          _buildSubItem('sidebar.task_types'.tr()),
        ],
      ),
    );
  }

  Widget _buildSubItem(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0, left: 12.0),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14.0, color: Color(0xFF6B7280)),
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: Column(
        children: [
          _buildNavItem(LucideIcons.userPlus, 'sidebar.create_user'.tr()),
          _buildLogoutButton(),
        ],
      ),
    );
  }

  Widget _buildLogoutButton() {
    return InkWell(
      onTap: () async => await ref.read(authStateProvider.notifier).logout(),
      child: Container(
        height: 48.0,
        padding: const EdgeInsets.symmetric(horizontal: 12.0),
        child: Row(
          mainAxisAlignment: widget.isExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            const Icon(LucideIcons.logOut, size: 24.0, color: Color(0xFFDC2626)),
            if (widget.isExpanded) ...[
              const SizedBox(width: 16.0),
              Text(
                'profile.sign_out'.tr(),
                style: const TextStyle(color: Color(0xFFDC2626), fontWeight: FontWeight.w600),
              ),
            ]
          ],
        ),
      ),
    );
  }
}