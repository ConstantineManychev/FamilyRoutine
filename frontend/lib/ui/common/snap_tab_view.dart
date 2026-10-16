import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const double tabSwipeThreshold = 0.2;
const Duration tabSnapDuration = Duration(milliseconds: 260);
const double wheelSwipeDistance = 120;
const Duration wheelGestureGap = Duration(milliseconds: 180);
const double _wheelRestartGrowth = 4;
const double _wheelRestartMinDelta = 6;
const Curve _snapCurve = Curves.easeOutCubic;

class HorizontalScrollZone extends StatelessWidget
{
  final Widget child;
  final bool isEnabled;

  const HorizontalScrollZone({super.key, required this.child, this.isEnabled = true});

  @override
  Widget build(BuildContext aContext) => _HorizontalZoneMarker(isEnabled: isEnabled, child: child);
}

class _HorizontalZoneMarker extends SingleChildRenderObjectWidget
{
  final bool isEnabled;

  const _HorizontalZoneMarker({required this.isEnabled, required super.child});

  @override
  RenderObject createRenderObject(BuildContext aContext) => _RenderHorizontalZone(isEnabled: isEnabled);

  @override
  void updateRenderObject(BuildContext aContext, _RenderHorizontalZone aRenderObject)
  {
    aRenderObject.isEnabled = isEnabled;
  }
}

class _RenderHorizontalZone extends RenderProxyBox
{
  bool isEnabled;

  _RenderHorizontalZone({required this.isEnabled});
}

typedef _WheelHandler = void Function(PointerScrollEvent aEvent, bool aIsInZone);

class _WheelFirst extends SingleChildRenderObjectWidget
{
  final _WheelHandler onWheel;

  const _WheelFirst({required this.onWheel, required super.child});

  @override
  RenderObject createRenderObject(BuildContext aContext) => _RenderWheelFirst(onWheel: onWheel);

  @override
  void updateRenderObject(BuildContext aContext, _RenderWheelFirst aRenderObject)
  {
    aRenderObject.onWheel = onWheel;
  }
}

class _RenderWheelFirst extends RenderProxyBox
{
  _WheelHandler onWheel;

  _RenderWheelFirst({required this.onWheel});

  @override
  bool hitTest(BoxHitTestResult aResult, {required Offset position})
  {
    if (!size.contains(position))
    {
      return false;
    }
    aResult.add(BoxHitTestEntry(this, position));
    hitTestChildren(aResult, position: position);
    return true;
  }

  @override
  void handleEvent(PointerEvent aEvent, covariant BoxHitTestEntry aEntry)
  {
    if (aEvent is PointerScrollEvent)
    {
      onWheel(aEvent, _isInZone(aEntry.localPosition));
    }
  }

  bool _isInZone(Offset aPosition)
  {
    final probe = BoxHitTestResult();
    child?.hitTest(probe, position: aPosition);
    return probe.path.any((aEntry) => aEntry.target is _RenderHorizontalZone && (aEntry.target as _RenderHorizontalZone).isEnabled);
  }
}

int swipeTarget({required int aAnchor, required double aPage, required int aCount})
{
  final shift = aPage - aAnchor;
  final target = shift.abs() >= tabSwipeThreshold ? aAnchor + shift.sign.toInt() : aAnchor;
  return target.clamp(0, aCount - 1);
}

class _SnapSimulation extends Simulation
{
  final double from;
  final double to;
  final double seconds;

  _SnapSimulation({required this.from, required this.to, required this.seconds});

  double _progress(double aTime) => (aTime / seconds).clamp(0.0, 1.0);

  @override
  double x(double aTime) => from + (to - from) * _snapCurve.transform(_progress(aTime));

  @override
  double dx(double aTime)
  {
    const step = 0.001;
    return (x(aTime + step) - x(aTime)) / step;
  }

  @override
  bool isDone(double aTime) => aTime >= seconds;
}

class TabSnapPhysics extends ScrollPhysics
{
  final TabController controller;

  const TabSnapPhysics({required this.controller, super.parent});

  @override
  TabSnapPhysics applyTo(ScrollPhysics? ancestor) => TabSnapPhysics(controller: controller, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity)
  {
    final width = position.viewportDimension;
    if (width <= 0)
    {
      return null;
    }
    final target = swipeTarget(aAnchor: controller.index, aPage: position.pixels / width, aCount: controller.length);
    final targetPixels = target * width;
    if ((targetPixels - position.pixels).abs() < 0.5)
    {
      return null;
    }
    return _SnapSimulation(
      from: position.pixels,
      to: targetPixels,
      seconds: tabSnapDuration.inMicroseconds / Duration.microsecondsPerSecond,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}

class SnapTabView extends StatefulWidget
{
  final TabController controller;
  final List<Widget> children;

  const SnapTabView({super.key, required this.controller, required this.children});

  @override
  State<SnapTabView> createState() => _SnapTabViewState();
}

class _SnapTabViewState extends State<SnapTabView>
{
  late final PageController _pages = PageController(initialPage: widget.controller.index);
  int _warpCount = 0;
  Drag? _wheelDrag;
  Timer? _wheelEnd;
  double _wheelShift = 0;
  double _wheelFollowed = 0;
  bool _isWheelStepped = false;
  Duration _wheelSteppedAt = Duration.zero;
  double _wheelQuietest = double.infinity;

  @override
  void initState()
  {
    super.initState();
    widget.controller.addListener(_onTabChanged);
  }

  @override
  void didUpdateWidget(covariant SnapTabView aOldWidget)
  {
    super.didUpdateWidget(aOldWidget);
    if (aOldWidget.controller != widget.controller)
    {
      aOldWidget.controller.removeListener(_onTabChanged);
      widget.controller.addListener(_onTabChanged);
    }
  }

  @override
  void dispose()
  {
    _wheelEnd?.cancel();
    widget.controller.removeListener(_onTabChanged);
    _pages.dispose();
    super.dispose();
  }

  Future<void> _onTabChanged() async
  {
    if (!_pages.hasClients || !widget.controller.indexIsChanging)
    {
      return;
    }
    _warpCount++;
    try
    {
      await _pages.animateToPage(widget.controller.index, duration: tabSnapDuration, curve: _snapCurve);
    }
    finally
    {
      _warpCount--;
    }
  }

  bool _onScroll(ScrollNotification aNotification)
  {
    if (_warpCount > 0 || aNotification.depth != 0 || !_pages.hasClients)
    {
      return false;
    }
    final controller = widget.controller;
    final page = _pages.page ?? controller.index.toDouble();
    if (aNotification is ScrollUpdateNotification && !controller.indexIsChanging)
    {
      if ((page - controller.index).abs() > 1.0)
      {
        controller.index = page.round();
      }
      controller.offset = (page - controller.index).clamp(-1.0, 1.0);
    }
    else if (aNotification is ScrollEndNotification)
    {
      controller.index = page.round();
      if (!controller.indexIsChanging)
      {
        controller.offset = (page - controller.index).clamp(-1.0, 1.0);
      }
    }
    return false;
  }

  Offset _wheelDelta(PointerScrollEvent aEvent)
  {
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    final isFlipped = aEvent.kind == PointerDeviceKind.mouse && HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains);
    return isFlipped ? Offset(aEvent.scrollDelta.dy, aEvent.scrollDelta.dx) : aEvent.scrollDelta;
  }

  void _ignoreSignal(PointerSignalEvent aEvent)
  {
  }

  void _blockPageScroll(PointerSignalEvent aEvent)
  {
    if (aEvent is PointerScrollEvent && _wheelDelta(aEvent).dx != 0)
    {
      GestureBinding.instance.pointerSignalResolver.register(aEvent, _ignoreSignal);
    }
  }

  void _onWheel(PointerScrollEvent aEvent, bool aIsInZone)
  {
    final delta = _wheelDelta(aEvent);
    if (!_pages.hasClients || aIsInZone || delta.dx == 0 || delta.dx.abs() <= delta.dy.abs())
    {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(aEvent, _ignoreSignal);
    if (_warpCount > 0 && !_isWheelStepped)
    {
      return;
    }

    _wheelEnd?.cancel();
    _wheelEnd = Timer(wheelGestureGap, _finishWheelGesture);
    if (_isWheelStepped)
    {
      if (!_isWheelRestart(aEvent.timeStamp, delta.dx.abs()))
      {
        return;
      }
      _resetWheel();
    }
    _followWheel(aEvent, delta.dx);
  }

  bool _isWheelRestart(Duration aTime, double aMagnitude)
  {
    final isRestart = aTime - _wheelSteppedAt >= tabSnapDuration &&
        aMagnitude >= math.max(_wheelRestartMinDelta, _wheelQuietest * _wheelRestartGrowth);
    _wheelQuietest = math.min(_wheelQuietest, aMagnitude);
    return isRestart;
  }

  void _followWheel(PointerScrollEvent aEvent, double aDx)
  {
    final position = _pages.position;
    final limit = math.min(position.viewportDimension * tabSwipeThreshold, wheelSwipeDistance);
    _wheelShift += aDx;
    final follow = _wheelShift.clamp(-limit, limit);
    _wheelDrag ??= position.drag(
      DragStartDetails(globalPosition: aEvent.position, sourceTimeStamp: aEvent.timeStamp, kind: aEvent.kind),
      () => _wheelDrag = null,
    );
    final step = follow - _wheelFollowed;
    if (step != 0)
    {
      _wheelDrag?.update(DragUpdateDetails(
        globalPosition: aEvent.position,
        sourceTimeStamp: aEvent.timeStamp,
        delta: Offset(-step, 0),
        primaryDelta: -step,
      ));
      _wheelFollowed = follow;
    }
    if (_wheelShift.abs() >= limit)
    {
      _stepWheel(aEvent.timeStamp);
    }
  }

  void _stepWheel(Duration aTime)
  {
    final controller = widget.controller;
    final target = (controller.index + _wheelShift.sign.toInt()).clamp(0, controller.length - 1);
    _isWheelStepped = true;
    _wheelSteppedAt = aTime;
    _wheelQuietest = double.infinity;
    _wheelDrag?.cancel();
    if (target != controller.index)
    {
      controller.animateTo(target, duration: tabSnapDuration, curve: _snapCurve);
    }
  }

  void _finishWheelGesture()
  {
    _wheelEnd = null;
    final drag = _wheelDrag;
    _resetWheel();
    drag?.end(DragEndDetails(primaryVelocity: 0));
  }

  void _resetWheel()
  {
    _wheelShift = 0;
    _wheelFollowed = 0;
    _isWheelStepped = false;
    _wheelQuietest = double.infinity;
  }

  @override
  Widget build(BuildContext aContext)
  {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: _WheelFirst(
        onWheel: _onWheel,
        child: PageView(
          controller: _pages,
          pageSnapping: false,
          physics: TabSnapPhysics(controller: widget.controller, parent: const ClampingScrollPhysics()),
          children: [
            for (final child in widget.children)
              Listener(behavior: HitTestBehavior.translucent, onPointerSignal: _blockPageScroll, child: child),
          ],
        ),
      ),
    );
  }
}
