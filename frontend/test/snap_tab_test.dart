import 'package:family_routine/ui/common/snap_tab_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _phone = Size(400, 800);

class _Host extends StatefulWidget
{
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin
{
  late final TabController tabs = TabController(length: 3, vsync: this, initialIndex: 1);

  @override
  void dispose()
  {
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    return MaterialApp(
      home: Scaffold(
        body: SnapTabView(
          controller: tabs,
          children: [
            for (final name in const ['groups', 'routine', 'finance']) Center(child: Text(name)),
          ],
        ),
      ),
    );
  }
}

Future<TabController> _pump(WidgetTester aTester) async
{
  await aTester.binding.setSurfaceSize(_phone);
  await aTester.pumpWidget(const _Host());
  return aTester.state<_HostState>(find.byType(_Host)).tabs;
}

Future<void> _drag(WidgetTester aTester, double aDx, {Duration aHold = Duration.zero}) async
{
  final gesture = await aTester.startGesture(const Offset(200, 400));
  const steps = 10;
  for (var step = 0; step < steps; step++)
  {
    await gesture.moveBy(Offset(aDx / steps, 0));
    await aTester.pump(aHold);
  }
  await gesture.up();
}

void main()
{
  test('swipe intent is decided by displacement and limited to the neighbour tab', ()
  {
    expect(swipeTarget(aAnchor: 1, aPage: 1.1, aCount: 3), 1);
    expect(swipeTarget(aAnchor: 1, aPage: 0.85, aCount: 3), 1);
    expect(swipeTarget(aAnchor: 1, aPage: 1.25, aCount: 3), 2);
    expect(swipeTarget(aAnchor: 1, aPage: 0.7, aCount: 3), 0);
    expect(swipeTarget(aAnchor: 0, aPage: 1.9, aCount: 3), 1);
    expect(swipeTarget(aAnchor: 2, aPage: 2.4, aCount: 3), 2);
    expect(swipeTarget(aAnchor: 0, aPage: -0.4, aCount: 3), 0);
  });

  testWidgets('a short drag returns to the same tab', (aTester) async
  {
    final tabs = await _pump(aTester);
    await _drag(aTester, -0.15 * _phone.width);
    await aTester.pump();
    await aTester.pump(tabSnapDuration);
    await aTester.pump();
    expect(tabs.index, 1);
    expect(find.text('routine'), findsOneWidget);
  });

  testWidgets('a slow drag past the threshold turns exactly one tab in the fixed time', (aTester) async
  {
    final tabs = await _pump(aTester);
    await _drag(aTester, -0.25 * _phone.width, aHold: const Duration(milliseconds: 60));
    await aTester.pump();
    await aTester.pump(tabSnapDuration);
    await aTester.pump();
    expect(tabs.index, 2);
    expect(aTester.hasRunningAnimations, isFalse);
  });

  testWidgets('a hard fling still turns only one tab and settles in the same time', (aTester) async
  {
    final tabs = await _pump(aTester);
    await aTester.flingFrom(const Offset(380, 400), const Offset(-370, 0), 8000);
    await aTester.pump();
    await aTester.pump(tabSnapDuration);
    await aTester.pump();
    expect(tabs.index, 2);
    expect(find.text('finance'), findsOneWidget);
    expect(aTester.hasRunningAnimations, isFalse);

    await aTester.flingFrom(const Offset(20, 400), const Offset(370, 0), 8000);
    await aTester.pump();
    await aTester.pump(tabSnapDuration);
    await aTester.pump();
    expect(tabs.index, 1);
  });

  testWidgets('tapping a tab animates to it', (aTester) async
  {
    final tabs = await _pump(aTester);
    tabs.animateTo(0);
    await aTester.pumpAndSettle();
    expect(find.text('groups'), findsOneWidget);
    expect(tabs.index, 0);
  });
}
