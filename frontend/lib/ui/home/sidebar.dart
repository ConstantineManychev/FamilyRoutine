import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../common/app_icons.dart';

const Map<String, String> _dictRoutes = {'exercises': '/app/exercises'};

class Sidebar extends ConsumerStatefulWidget
{
  final bool isExpanded;
  final VoidCallback? onToggle;
  final VoidCallback? onNavigated;
  final String fName;
  final String lName;
  final List<FamDto> families;

  const Sidebar({
    super.key,
    required this.isExpanded,
    this.onToggle,
    this.onNavigated,
    required this.fName,
    required this.lName,
    required this.families,
  });

  @override
  ConsumerState<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends ConsumerState<Sidebar>
{
  bool _isDictExpanded = false;
  bool _isFamOpen = false;
  bool _isFamHovered = false;

  String get _initials
  {
    final first = widget.fName.isNotEmpty ? widget.fName[0] : '';
    final last = widget.lName.isNotEmpty ? widget.lName[0] : '';
    final initials = '$first$last'.toUpperCase();
    return initials.isEmpty ? '?' : initials;
  }

  void _go(String aPath)
  {
    context.go(aPath);
    widget.onNavigated?.call();
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

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

  Widget _buildNavList()
  {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 12.0),
      children: [
        _buildNavItem(AppIcons.home, 'sidebar.routine'.tr(), () => _go('/app')),
        _buildFamMenu(),
        _buildNavItem(AppIcons.listChecks, 'sidebar.transactions'.tr(), () => _go('/app/transactions')),
        _buildNavItem(AppIcons.receipt, 'sidebar.receipts'.tr(), () => _go('/app/receipts')),
        _buildNavItem(AppIcons.wallet, 'sidebar.wallets'.tr(), () => _go('/app/wallets')),
        if (widget.isExpanded) ...[
          const SizedBox(height: 24.0),
          _buildSectionTitle('sidebar.references'.tr()),
          _buildDictMenu(),
        ],
        const SizedBox(height: 24.0),
        _buildNavItem(AppIcons.settings, 'sidebar.settings'.tr(), null),
      ],
    );
  }

  Widget _buildFamMenu()
  {
    final isListVisible = widget.isExpanded && (_isFamOpen || _isFamHovered);

    return MouseRegion(
      onEnter: (_) => setState(() => _isFamHovered = true),
      onExit: (_) => setState(() => _isFamHovered = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildNavItem(
            AppIcons.users,
            'sidebar.family_groups'.tr(),
            () => _go('/app/families'),
            aTrailing: widget.isExpanded
                ? IconButton(
                    tooltip: 'sidebar.toggle_list'.tr(),
                    icon: Icon(_isFamOpen ? AppIcons.chevronUp : AppIcons.chevronDown, size: 18),
                    onPressed: () => setState(() => _isFamOpen = !_isFamOpen),
                  )
                : null,
          ),
          if (isListVisible) ...[
            ...widget.families.map((aFam) => _buildSubItem(aFam.name, () => _go('/app/families/${aFam.id}'))),
            _buildSubItem('sidebar.create'.tr(), () => _go('/app/families/new'), aIcon: AppIcons.plusCircle),
          ],
        ],
      ),
    );
  }

  Widget _buildDictMenu()
  {
    final serverDicts = ref.watch(dictsMetaProv).valueOrNull ?? const [];

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
                Icon(_isDictExpanded ? AppIcons.chevronUp : AppIcons.chevronDown, size: 18.0),
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
                      _buildSubItem('sidebar.places'.tr(), () => _go('/app/places'), aIcon: AppIcons.mapPin),
                      _buildSubItem('sidebar.cities'.tr(), () => _go('/app/cities'), aIcon: AppIcons.building2),
                      _buildSubItem('sidebar.streets'.tr(), () => _go('/app/streets'), aIcon: AppIcons.navigation),
                      ...serverDicts.map((aDict)
                      {
                        final route = _dictRoutes[aDict.id];
                        return _buildSubItem(
                          aDict.name.tr(),
                          route == null ? null : () => _go(route),
                          aIcon: AppIcons.bookOpen,
                        );
                      }),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildHeader()
  {
    return Container(
      height: 96.0,
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6)))),
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
          ],
        ],
      ),
    );
  }

  Widget _buildAvatar()
  {
    return Tooltip(
      message: widget.onToggle == null ? '' : 'sidebar.toggle_menu'.tr(),
      child: GestureDetector(
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
      ),
    );
  }

  Widget _buildNavItem(IconData aIcon, String aLabel, VoidCallback? aOnTap, {Widget? aTrailing})
  {
    final isEnabled = aOnTap != null;
    final color = isEnabled ? const Color(0xFF374151) : const Color(0xFFB0B6BF);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Tooltip(
        message: isEnabled ? (widget.isExpanded ? '' : aLabel) : 'common.soon'.tr(),
        child: InkWell(
          borderRadius: BorderRadius.circular(12.0),
          onTap: aOnTap,
          child: Container(
            height: 48.0,
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              mainAxisAlignment: widget.isExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(aIcon, size: 24.0, color: color),
                if (widget.isExpanded) ...[
                  const SizedBox(width: 16.0),
                  Expanded(
                    child: Text(
                      aLabel,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16.0, color: color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (aTrailing != null) aTrailing,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String aTitle)
  {
    return Padding(
      padding: const EdgeInsets.only(left: 12.0, bottom: 8.0),
      child: Text(
        aTitle.toUpperCase(),
        style: const TextStyle(
          fontSize: 10.0,
          fontWeight: FontWeight.bold,
          color: Color(0xFF9CA3AF),
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildSubItem(String aLabel, VoidCallback? aOnTap, {IconData? aIcon})
  {
    final color = aOnTap == null ? const Color(0xFFB0B6BF) : const Color(0xFF6B7280);

    return Tooltip(
      message: aOnTap == null ? 'common.soon'.tr() : '',
      child: InkWell(
        onTap: aOnTap,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12.0, left: 12.0, top: 4.0),
          child: Row(
            children: [
              if (aIcon != null) ...[
                Icon(aIcon, size: 16.0, color: color),
                const SizedBox(width: 8.0),
              ],
              Expanded(
                child: Text(
                  aLabel,
                  style: TextStyle(fontSize: 14.0, color: color),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter()
  {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFF3F4F6)))),
      child: _buildNavItem(AppIcons.logOut, 'profile.sign_out'.tr(), ()
      {
        widget.onNavigated?.call();
        ref.read(authProv.notifier).logout();
      }),
    );
  }
}
