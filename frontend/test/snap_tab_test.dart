import 'dart:math' as math;

import 'package:family_routine/ui/common/snap_tab_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const Size _phone = Size(400, 800);
const Size _laptop = Size(1280, 800);
const Duration _wheelTick = Duration(milliseconds: 16);
const Offset _pointer = Offset(640, 400);

class _Host extends StatefulWidget
{
  final int initialIndex;
  final bool hasInnerScroller;

  const _Host({this.initialIndex = 1, this.hasInnerScroller = false});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin
{
  late final TabController tabs = TabController(length: 3, vsync: this, initialIndex: widget.initialIndex);

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
            for (final name in const ['groups', 'routine', 'finance'])
              widget.hasInnerScroller ? HorizontalScrollZone(child: Center(child: Text(name))) : Center(child: Text(name)),
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

Future<TabController> _pumpLaptop(WidgetTester aTester, {int aIndex = 1, bool aHasInnerScroller = false}) async
{
  await aTester.binding.setSurfaceSize(_laptop);
  await aTester.pumpWidget(_Host(initialIndex: aIndex, hasInnerScroller: aHasInnerScroller));
  return aTester.state<_HostState>(find.byType(_Host)).tabs;
}

double _pixels(WidgetTester aTester) => aTester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

List<Offset> _swipe(double aDx, {int aFingerTicks = 8, int aInertiaTicks = 0, double aDecay = 0.93})
{
  return [
    for (var tick = 0; tick < aFingerTicks; tick++) Offset(aDx, 0),
    for (var tick = 1; tick <= aInertiaTicks; tick++) Offset(aDx * math.pow(aDecay, tick), 0),
  ];
}

Future<List<double>> _wheel(WidgetTester aTester, List<Offset> aDeltas, {Duration aStart = Duration.zero}) async
{
  final positions = <double>[];
  var time = aStart;
  for (final delta in aDeltas)
  {
    aTester.binding.handlePointerEvent(PointerScrollEvent(
      timeStamp: time,
      kind: PointerDeviceKind.trackpad,
      position: _pointer,
      scrollDelta: delta,
    ));
    await aTester.pump(_wheelTick);
    positions.add(_pixels(aTester));
    time += _wheelTick;
  }
  return positions;
}

Future<void> _settle(WidgetTester aTester) async
{
  await aTester.pump(wheelGestureGap);
  await aTester.pump();
  await aTester.pump(tabSnapDuration);
  await aTester.pump();
}

bool _isMonotonic(List<double> aValues, {required bool aIsRising})
{
  for (var index = 1; index < aValues.length; index++)
  {
    final step = aValues[index] - aValues[index - 1];
    if (aIsRising ? step < -0.01 : step > 0.01)
    {
      return false;
    }
  }
  return true;
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

  testWidgets('a trackpad swipe with a long inertial tail turns exactly one tab without bouncing', (aTester) async
  {
    final tabs = await _pumpLaptop(aTester);
    final positions = await _wheel(aTester, _swipe(30, aInertiaTicks: 90));
    await _settle(aTester);

    expect(tabs.index, 2);
    expect(_pixels(aTester), 2 * _laptop.width);
    expect(_isMonotonic(positions, aIsRising: true), isTrue);
    expect(aTester.hasRunningAnimations, isFalse);
  });

  testWidgets('a short trackpad swipe follows the fingers and only then returns', (aTester) async
  {
    final tabs = await _pumpLaptop(aTester);
    final positions = await _wheel(aTester, _swipe(-12, aFingerTicks: 5));

    expect(_isMonotonic(positions, aIsRising: false), isTrue);
    expect(positions.last, closeTo(_laptop.width - 60, 0.5));
    await _settle(aTester);
    expect(tabs.index, 1);
    expect(_pixels(aTester), _laptop.width);
  });

  testWidgets('a second trackpad swipe during the inertia of the first turns the next tab', (aTester) async
  {
    final tabs = await _pumpLaptop(aTester, aIndex: 0);
    final first = _swipe(25, aInertiaTicks: 15, aDecay: 0.8);
    await _wheel(aTester, first);
    await _wheel(aTester, _swipe(25), aStart: _wheelTick * first.length);
    await _settle(aTester);

    expect(tabs.index, 2);
    expect(_pixels(aTester), 2 * _laptop.width);
  });

  testWidgets('vertical and claimed horizontal scrolling leave the tabs alone', (aTester) async
  {
    final tabs = await _pumpLaptop(aTester);
    await _wheel(aTester, [for (var tick = 0; tick < 20; tick++) const Offset(6, 40)]);
    await _settle(aTester);
    expect(tabs.index, 1);
    expect(_pixels(aTester), _laptop.width);

    final zoned = await _pumpLaptop(aTester, aHasInnerScroller: true);
    await _wheel(aTester, _swipe(30, aInertiaTicks: 30));
    await _settle(aTester);
    expect(zoned.index, 1);
    expect(_pixels(aTester), _laptop.width);
  });

  testWidgets('a trackpad swipe past the last tab springs back', (aTester) async
  {
    final tabs = await _pumpLaptop(aTester, aIndex: 2);
    await _wheel(aTester, _swipe(30, aInertiaTicks: 30));
    await _settle(aTester);
    expect(tabs.index, 2);
    expect(_pixels(aTester), 2 * _laptop.width);
    expect(aTester.takeException(), isNull);
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
