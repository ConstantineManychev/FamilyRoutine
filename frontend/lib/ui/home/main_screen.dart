import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import 'sidebar.dart';

const double compactLayoutWidth = 760;

class MainScreen extends ConsumerStatefulWidget
{
  final Widget child;

  const MainScreen({super.key, required this.child});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
{
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isExpanded = true;

  void _toggleMenu()
  {
    setState(() => _isExpanded = !_isExpanded);
  }

  @override
  Widget build(BuildContext aContext)
  {
    final user = ref.watch(authProv.select((aState) => aState.user));
    final fams = ref.watch(famsProv).valueOrNull ?? const [];
    final isCompact = MediaQuery.sizeOf(aContext).width < compactLayoutWidth;

    if (isCompact)
    {
      return Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(title: const Text('Family Routine')),
        drawer: Drawer(
          child: SafeArea(
            child: Sidebar(
              isExpanded: true,
              fName: user?.fName ?? '',
              lName: user?.lName ?? '',
              families: fams,
              onNavigated: () => _scaffoldKey.currentState?.closeDrawer(),
            ),
          ),
        ),
        body: widget.child,
      );
    }

    return Scaffold(
      body: Row(
        children: [
          Sidebar(
            isExpanded: _isExpanded,
            onToggle: _toggleMenu,
            fName: user?.fName ?? '',
            lName: user?.lName ?? '',
            families: fams,
          ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}
