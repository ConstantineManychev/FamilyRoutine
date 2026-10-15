import 'package:flutter/material.dart';

const double tabSwipeThreshold = 0.2;
const Duration tabSnapDuration = Duration(milliseconds: 260);
const Curve _snapCurve = Curves.easeOutCubic;

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

  @override
  Widget build(BuildContext aContext)
  {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView(
        controller: _pages,
        pageSnapping: false,
        physics: TabSnapPhysics(controller: widget.controller, parent: const ClampingScrollPhysics()),
        children: widget.children,
      ),
    );
  }
}
