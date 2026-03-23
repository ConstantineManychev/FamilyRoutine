import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import 'sidebar.dart';

class MainScreen extends ConsumerStatefulWidget {
  final Widget child;

  const MainScreen({super.key, required this.child});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  bool _isExpanded = true;

  void _toggleMenu() {
    setState(() {
      _isExpanded = !_isExpanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final profAsync = ref.watch(profProv);
    final famsAsync = ref.watch(famsProv);

    return Scaffold(
      body: Row(
        children: [
          Sidebar(
            isExpanded: _isExpanded,
            onToggle: _toggleMenu,
            fName: profAsync.valueOrNull?.fName ?? '',
            lName: profAsync.valueOrNull?.lName ?? '',
            families: famsAsync.valueOrNull ?? [],
          ),
          Expanded(
            child: widget.child,
          ),
        ],
      ),
    );
  }
}