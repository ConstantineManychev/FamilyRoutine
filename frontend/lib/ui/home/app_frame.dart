import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';

class _DictLink
{
  final String label;
  final IconData icon;
  final String route;

  const _DictLink(this.label, this.icon, this.route);
}

const Map<String, (IconData, String)> _serverDictRoutes = {
  'items': (AppIcons.package, '/app/items'),
  'exercises': (AppIcons.dumbbell, '/app/exercises'),
};

class AppFrame extends ConsumerStatefulWidget
{
  final Widget child;

  const AppFrame({super.key, required this.child});

  @override
  ConsumerState<AppFrame> createState() => _AppFrameState();
}

class _AppFrameState extends ConsumerState<AppFrame>
{
  bool _isOpen = false;

  void _toggle() => setState(() => _isOpen = !_isOpen);

  void _open(String aRoute)
  {
    setState(() => _isOpen = false);
    GoRouter.of(context).push(aRoute);
  }

  List<_DictLink> _links()
  {
    final serverDicts = ref.watch(dictsMetaProv).valueOrNull ?? const [];
    return [
      for (final dict in serverDicts)
        if (_serverDictRoutes[dict.id] case final target?) _DictLink(dict.name.tr(), target.$1, target.$2),
      _DictLink('sidebar.places'.tr(), AppIcons.mapPin, '/app/places'),
      _DictLink('sidebar.cities'.tr(), AppIcons.building2, '/app/cities'),
      _DictLink('sidebar.streets'.tr(), AppIcons.navigation, '/app/streets'),
    ];
  }

  @override
  Widget build(BuildContext aContext)
  {
    Localizations.localeOf(aContext);
    final media = MediaQuery.of(aContext);
    final isKeyboardShown = media.viewInsets.bottom > 0;
    final links = _isOpen ? _links() : const <_DictLink>[];

    return Stack(
      children: [
        widget.child,
        if (_isOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: ColoredBox(color: Colors.black.withValues(alpha: 0.32)),
            ),
          ),
        if (!isKeyboardShown)
          Positioned(
            right: 16,
            bottom: 16 + media.padding.bottom,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final link in links)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _DictAction(link: link, onTap: () => _open(link.route)),
                  ),
                FloatingActionButton(
                  heroTag: 'dicts',
                  tooltip: _isOpen ? 'common.close'.tr() : 'sidebar.dictionaries'.tr(),
                  onPressed: _toggle,
                  child: Icon(_isOpen ? AppIcons.x : AppIcons.library),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DictAction extends StatelessWidget
{
  final _DictLink link;
  final VoidCallback onTap;

  const _DictAction({required this.link, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    return Material(
      color: aContext.colors.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(link.icon, size: 18, color: aContext.colors.primary),
              const SizedBox(width: 10),
              Text(link.label, style: TextStyle(fontWeight: FontWeight.w600, color: aContext.palette.inkPrimary)),
            ],
          ),
        ),
      ),
    );
  }
}
