import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/api_prov.dart';

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
  bool _isFamHovered = false;
  List<DictMetaDto> _dicts = [];

  String get _initials {
    if (widget.fName.isNotEmpty && widget.lName.isNotEmpty) {
      return '${widget.fName[0]}${widget.lName[0]}'.toUpperCase();
    }
    return widget.fName.isNotEmpty ? widget.fName[0].toUpperCase() : '?';
  }

  @override
  void initState() {
    super.initState();
    _fetchDicts();
  }

  Future<void> _fetchDicts() async {
    final api = ref.read(apiProv);
    try {
      final res = await api.getDictsMeta();
      if (mounted) setState(() => _dicts = res);
    } catch (_) {}
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
          Expanded(child: _buildNavList()),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildNavList() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 12.0),
      children: [
        _buildNavItem(LucideIcons.home, 'sidebar.routine'.tr(), () {
          context.go('/app');
        }),
        _buildFamMenu(),
        if (widget.isExpanded) ...[
          const SizedBox(height: 24.0),
          _buildSectionTitle('sidebar.references'.tr()),
          _buildDictMenu(),
        ],
        const SizedBox(height: 24.0),
        _buildNavItem(LucideIcons.settings, 'sidebar.settings'.tr(), () {}),
      ],
    );
  }

  Widget _buildFamMenu() {
    return MouseRegion(
      onEnter: (_) => setState(() => _isFamHovered = true),
      onExit: (_) => setState(() => _isFamHovered = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildNavItem(LucideIcons.users, 'sidebar.family_groups'.tr(), () {
            context.go('/app/families');
          }),
          if (widget.isExpanded && _isFamHovered) ...[
            ...widget.families.map((f) => _buildSubItem(f.name, () {
                  context.go('/app/families/${f.id}');
                })),
            _buildSubItem('sidebar.create'.tr(), () {
              context.go('/app/families/new');
            }, icon: LucideIcons.plusCircle),
          ],
        ],
      ),
    );
  }

  Widget _buildDictMenu() {
    return Column(
      children: [
        InkWell(
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
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _isDictExpanded
              ? Padding(
                  padding: const EdgeInsets.only(left: 16.0, top: 8.0),
                  child: Column(
                    children: [
                      _buildSubItem('sidebar.wallets'.tr(), () => context.go('/app/wallets'), icon: LucideIcons.wallet),
                      _buildSubItem('sidebar.places'.tr(), () => context.go('/app/places'), icon: LucideIcons.mapPin),
                      _buildSubItem('sidebar.cities'.tr(), () => context.go('/app/cities'), icon: LucideIcons.building2),
                      _buildSubItem('sidebar.streets'.tr(), () => context.go('/app/streets'), icon: LucideIcons.navigation),
                      ..._dicts.map((d) => _buildSubItem(d.name.tr(), () {
                            if (d.id == 'exercises') context.go('/app/exercises');
                          })).toList(),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
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
            Expanded(
              child: Text(
                '${widget.fName} ${widget.lName}',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.0, color: Color(0xFF1F2937)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
        decoration: const BoxDecoration(color: Color(0xFF2563EB), shape: BoxShape.circle),
        child: Center(
          child: Text(
            _initials,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18.0),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12.0),
        onTap: onTap,
        child: Container(
          height: 48.0,
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            mainAxisAlignment: widget.isExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
            children: [
              Icon(icon, size: 24.0, color: const Color(0xFF4B5563)),
              if (widget.isExpanded) ...[
                const SizedBox(width: 16.0),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16.0, color: Color(0xFF374151)),
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                  ),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 12.0, bottom: 8.0),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(fontSize: 10.0, fontWeight: FontWeight.bold, color: Color(0xFF9CA3AF), letterSpacing: 1.2),
      ),
    );
  }

  Widget _buildSubItem(String label, VoidCallback onTap, {IconData? icon}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12.0, left: 12.0),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16.0, color: const Color(0xFF6B7280)),
              const SizedBox(width: 8.0),
            ],
            Text(label, style: const TextStyle(fontSize: 14.0, color: Color(0xFF6B7280))),
          ],
        ),
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
          _buildNavItem(LucideIcons.userPlus, 'sidebar.create_user'.tr(), () {}),
          _buildNavItem(LucideIcons.logOut, 'profile.sign_out'.tr(), () async {
            await ref.read(authStateProvider.notifier).logout();
          }),
        ],
      ),
    );
  }
}