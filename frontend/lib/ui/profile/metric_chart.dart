import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/money.dart';
import 'metric_format.dart';

const double _chartHeight = 240;
const double _axisWidth = 52;
const double _labelHeight = 22;
const double _pointRadius = 4;
const double _hitRadius = 28;
const Color measureColor = Color(0xFF2A78D6);
const Color trendColor = Color(0xFFE8833A);

class MetricChart extends StatefulWidget
{
  final BodyMetric metric;
  final List<MetricPoint> points;
  final List<double>? trend;

  const MetricChart({super.key, required this.metric, required this.points, this.trend});

  @override
  State<MetricChart> createState() => _MetricChartState();
}

class _MetricChartState extends State<MetricChart>
{
  int? _hoverIndex;

  void _updateHover(Offset aPosition, Size aSize)
  {
    final layout = _ChartLayout(widget.points, widget.trend, aSize);
    int? nearest;
    var bestDistance = double.infinity;
    for (var index = 0; index < widget.points.length; index++)
    {
      final distance = (layout.xOf(widget.points[index].measuredTs) - aPosition.dx).abs();
      if (distance < bestDistance)
      {
        bestDistance = distance;
        nearest = index;
      }
    }
    final next = bestDistance <= _hitRadius || widget.points.length > 1 ? nearest : null;
    if (next != _hoverIndex)
    {
      setState(() => _hoverIndex = next);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final trend = widget.trend;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (trend != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 20,
              runSpacing: 6,
              children: [
                _LegendEntry(color: measureColor, label: 'metrics.series_measured'.tr(), isDot: true),
                _LegendEntry(color: trendColor, label: 'metrics.series_trend'.tr(), isDot: false),
              ],
            ),
          ),
        LayoutBuilder(
          builder: (aLayoutContext, aConstraints)
          {
            final size = Size(aConstraints.maxWidth, _chartHeight + _labelHeight);
            final hovered = _hoverIndex == null ? null : widget.points[_hoverIndex!];

            return MouseRegion(
              onHover: (aEvent) => _updateHover(aEvent.localPosition, size),
              onExit: (_) => setState(() => _hoverIndex = null),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (aDetails) => _updateHover(aDetails.localPosition, size),
                onHorizontalDragUpdate: (aDetails) => _updateHover(aDetails.localPosition, size),
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _MetricPainter(
                            points: widget.points,
                            trend: trend,
                            hoverIndex: _hoverIndex,
                            valueLabel: (aValue) => formatMetricNumber(aContext, aValue),
                            dateLabel: (aTs, aSpan) => aSpan.inDays > 300
                                ? DateFormat.yMMM(aContext.locale.toLanguageTag()).format(aTs)
                                : DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aTs),
                          ),
                        ),
                      ),
                      if (hovered != null) _buildTooltip(aContext, size, hovered),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildTooltip(BuildContext aContext, Size aSize, MetricPoint aPoint)
  {
    const tooltipWidth = 180.0;
    final layout = _ChartLayout(widget.points, widget.trend, aSize);
    final x = layout.xOf(aPoint.measuredTs);
    final left = (x + 12 + tooltipWidth > aSize.width ? x - 12 - tooltipWidth : x + 12)
        .clamp(0.0, math.max(0.0, aSize.width - tooltipWidth))
        .toDouble();
    final trend = widget.trend;

    return Positioned(
      left: left,
      top: 4,
      width: tooltipWidth,
      child: IgnorePointer(
        child: Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(8),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatMeasuredTs(aContext, aPoint.measuredTs), style: const TextStyle(color: inkSecondary, fontSize: 12)),
                const SizedBox(height: 6),
                _TooltipRow(
                  color: measureColor,
                  label: 'metrics.series_measured'.tr(),
                  value: formatMetric(aContext, widget.metric, aPoint.value),
                ),
                if (trend != null)
                  _TooltipRow(
                    color: trendColor,
                    label: 'metrics.series_trend'.tr(),
                    value: formatMetric(aContext, widget.metric, double.parse(trend[_hoverIndex!].toStringAsFixed(2))),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartLayout
{
  final double minValue;
  final double maxValue;
  final DateTime start;
  final DateTime end;
  final Size size;

  factory _ChartLayout(List<MetricPoint> aPoints, List<double>? aTrend, Size aSize)
  {
    final values = [...aPoints.map((aPoint) => aPoint.value), ...?aTrend];
    var low = values.reduce(math.min);
    var high = values.reduce(math.max);
    final padding = math.max((high - low) * 0.15, math.max(high.abs() * 0.01, 0.5));
    low -= padding;
    high += padding;
    final start = aPoints.first.measuredTs;
    final end = aPoints.length > 1 ? aPoints.last.measuredTs : start.add(const Duration(days: 1));
    return _ChartLayout._(low, high, start, end, aSize);
  }

  const _ChartLayout._(this.minValue, this.maxValue, this.start, this.end, this.size);

  double get plotLeft => _axisWidth;

  double get plotRight => size.width - 12;

  double get plotHeight => size.height - _labelHeight;

  Duration get span => end.difference(start);

  double xOf(DateTime aTs)
  {
    final total = span.inSeconds;
    if (total <= 0)
    {
      return (plotLeft + plotRight) / 2;
    }
    return plotLeft + (plotRight - plotLeft) * aTs.difference(start).inSeconds / total;
  }

  double yOf(double aValue) => 8 + (plotHeight - 16) * (1 - (aValue - minValue) / (maxValue - minValue));
}

class _MetricPainter extends CustomPainter
{
  final List<MetricPoint> points;
  final List<double>? trend;
  final int? hoverIndex;
  final String Function(double) valueLabel;
  final String Function(DateTime, Duration) dateLabel;

  _MetricPainter({
    required this.points,
    required this.trend,
    required this.hoverIndex,
    required this.valueLabel,
    required this.dateLabel,
  });

  void _paintText(Canvas aCanvas, String aText, Offset aAnchor, TextAlign aAlign, double aMaxWidth)
  {
    final painter = TextPainter(
      text: TextSpan(text: aText, style: const TextStyle(color: inkMuted, fontSize: 11)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: aMaxWidth);
    final dx = switch (aAlign)
    {
      TextAlign.right => aAnchor.dx - painter.width,
      TextAlign.center => aAnchor.dx - painter.width / 2,
      _ => aAnchor.dx,
    };
    painter.paint(aCanvas, Offset(dx, aAnchor.dy - painter.height / 2));
  }

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    if (points.isEmpty)
    {
      return;
    }

    final layout = _ChartLayout(points, trend, aSize);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var step = 0; step <= 3; step++)
    {
      final value = layout.minValue + (layout.maxValue - layout.minValue) * step / 3;
      final y = layout.yOf(value);
      aCanvas.drawLine(Offset(layout.plotLeft, y), Offset(layout.plotRight, y), gridPaint);
      _paintText(aCanvas, valueLabel(double.parse(value.toStringAsFixed(1))), Offset(layout.plotLeft - 8, y), TextAlign.right, _axisWidth - 8);
    }

    if (hoverIndex != null)
    {
      final x = layout.xOf(points[hoverIndex!].measuredTs);
      aCanvas.drawLine(Offset(x, 0), Offset(x, layout.plotHeight), Paint()..color = baselineColor..strokeWidth = 1);
    }

    final measured = Path();
    for (var index = 0; index < points.length; index++)
    {
      final offset = Offset(layout.xOf(points[index].measuredTs), layout.yOf(points[index].value));
      index == 0 ? measured.moveTo(offset.dx, offset.dy) : measured.lineTo(offset.dx, offset.dy);
    }
    aCanvas.drawPath(
      measured,
      Paint()
        ..color = measureColor.withValues(alpha: trend == null ? 1 : 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final trendValues = trend;
    if (trendValues != null && trendValues.length == points.length)
    {
      final trendPath = Path();
      for (var index = 0; index < points.length; index++)
      {
        final offset = Offset(layout.xOf(points[index].measuredTs), layout.yOf(trendValues[index]));
        index == 0 ? trendPath.moveTo(offset.dx, offset.dy) : trendPath.lineTo(offset.dx, offset.dy);
      }
      aCanvas.drawPath(
        trendPath,
        Paint()
          ..color = trendColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    for (var index = 0; index < points.length; index++)
    {
      final center = Offset(layout.xOf(points[index].measuredTs), layout.yOf(points[index].value));
      final radius = index == hoverIndex ? _pointRadius + 2 : _pointRadius;
      aCanvas.drawCircle(center, radius + 2, Paint()..color = Colors.white);
      aCanvas.drawCircle(center, radius, Paint()..color = measureColor);
    }

    final labelCount = math.max(2, ((layout.plotRight - layout.plotLeft) / 90).floor());
    final span = layout.span;
    for (var step = 0; step < labelCount; step++)
    {
      final fraction = labelCount == 1 ? 0.5 : step / (labelCount - 1);
      final ts = layout.start.add(Duration(seconds: (span.inSeconds * fraction).round()));
      final align = step == 0 ? TextAlign.left : step == labelCount - 1 ? TextAlign.right : TextAlign.center;
      _paintText(aCanvas, dateLabel(ts, span), Offset(layout.xOf(ts), layout.plotHeight + _labelHeight / 2), align, 90);
    }
  }

  @override
  bool shouldRepaint(covariant _MetricPainter aOld) =>
      aOld.points != points || aOld.trend != trend || aOld.hoverIndex != hoverIndex;
}

class _LegendEntry extends StatelessWidget
{
  final Color color;
  final String label;
  final bool isDot;

  const _LegendEntry({required this.color, required this.label, required this.isDot});

  @override
  Widget build(BuildContext aContext)
  {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: isDot ? 10 : 18,
          height: isDot ? 10 : 3,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(isDot ? 5 : 2)),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: inkSecondary)),
      ],
    );
  }
}

class _TooltipRow extends StatelessWidget
{
  final Color color;
  final String label;
  final String value;

  const _TooltipRow({required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext aContext)
  {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: const TextStyle(color: inkSecondary, fontSize: 13))),
          Text(value, style: const TextStyle(color: inkPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
