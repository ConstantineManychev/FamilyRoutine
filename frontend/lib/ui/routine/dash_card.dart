import 'package:flutter/material.dart';

import '../common/money.dart';

class DashCard extends StatelessWidget
{
  final Widget title;
  final List<Widget> actions;
  final Widget? menu;
  final Widget child;

  const DashCard({super.key, required this.title, this.actions = const [], this.menu, required this.child});

  @override
  Widget build(BuildContext aContext)
  {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DefaultTextStyle.merge(
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: inkPrimary),
                      child: title,
                    ),
                    ...actions,
                  ],
                ),
              ),
              if (menu != null) menu!,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
