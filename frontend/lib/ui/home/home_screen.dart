import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/auth_provider.dart';
import '../common/app_theme.dart';
import 'finance_tab.dart';
import 'groups_tab.dart';
import 'routine_tab.dart';

enum HomeTab
{
  groups,
  routine,
  finance;

  static HomeTab parse(String? aValue)
  {
    for (final tab in HomeTab.values)
    {
      if (tab.name == aValue)
      {
        return tab;
      }
    }
    return HomeTab.routine;
  }
}

class HomeScreen extends ConsumerStatefulWidget
{
  final String? initialTab;

  const HomeScreen({super.key, this.initialTab});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with SingleTickerProviderStateMixin
{
  late final TabController _tabs = TabController(
    length: HomeTab.values.length,
    vsync: this,
    initialIndex: HomeTab.parse(widget.initialTab).index,
  );

  @override
  void didUpdateWidget(covariant HomeScreen aOldWidget)
  {
    super.didUpdateWidget(aOldWidget);
    if (widget.initialTab != null && widget.initialTab != aOldWidget.initialTab)
    {
      _tabs.animateTo(HomeTab.parse(widget.initialTab).index);
    }
  }

  @override
  void dispose()
  {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final user = ref.watch(authProv.select((aState) => aState.user));
    final fullName = [user?.fName ?? '', user?.lName ?? ''].where((aPart) => aPart.isNotEmpty).join(' ');
    final initials = [user?.fName ?? '', user?.lName ?? '']
        .where((aPart) => aPart.isNotEmpty)
        .map((aPart) => aPart.characters.first.toUpperCase())
        .join();

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        titleSpacing: 8,
        title: Semantics(
          button: true,
          label: 'home.open_profile'.tr(),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: () => aContext.push('/app/profile'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: aContext.colors.primary,
                    foregroundColor: aContext.colors.onPrimary,
                    child: Text(initials.isEmpty ? '?' : initials, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: aContext.palette.inkPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: 'home.tab_groups'.tr()),
            Tab(text: 'home.tab_routine'.tr()),
            Tab(text: 'home.tab_finance'.tr()),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          GroupsTab(),
          RoutineTab(),
          FinanceTab(),
        ],
      ),
    );
  }
}
