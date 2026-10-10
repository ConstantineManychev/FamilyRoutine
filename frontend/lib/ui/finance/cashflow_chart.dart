import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/money.dart';

const double _chartHeight = 220;
const double _axisWidth = 56;
const double _labelHeight = 22;
const double _maxBarWidth = 24;
const double _barRadius = 4;

class CashflowChart extends StatefulWidget
{
  final CashflowSeries series;
  final StatsBucket bucket;

  const CashflowChart({super.key, required this.series, required this.bucket});

  @override
  State<CashflowChart> createState() => _CashflowChartState();
}

class _CashflowChartState extends State<CashflowChart>
{
  int? _hoverIndex;
  bool _isTableVisible = false;

  String _bucketLabel(BuildContext aContext, DateTime aTs)
  {
    final locale = aContext.locale.toLanguageTag();
    return widget.bucket == StatsBucket.hour ? DateFormat.Hm(locale).format(aTs) : DateFormat.MMMd(locale).format(aTs);
  }

  String _bucketTitle(BuildContext aContext, DateTime aTs)
  {
    final locale = aContext.locale.toLanguageTag();
    return widget.bucket == StatsBucket.hour
        ? DateFormat.MMMd(locale).add_Hm().format(aTs)
        : DateFormat.yMMMEd(locale).format(aTs);
  }

  void _updateHover(Offset aPosition, double aPlotWidth)
  {
    final points = widget.series.points;
    if (points.isEmpty)
    {
      return;
    }

    final slot = aPlotWidth / points.length;
    final index = ((aPosition.dx - _axisWidth) / slot).floor();
    final next = index >= 0 && index < points.length ? index : null;

    if (next != _hoverIndex)
    {
      setState(() => _hoverIndex = next);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final series = widget.series;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 20,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _LegendEntry(
              color: incomeColor,
              label: 'finance.income'.tr(),
              value: formatMoney(aContext, series.incomeTotal, series.currCode),
            ),
            _LegendEntry(
              color: expenseColor,
              label: 'finance.expense'.tr(),
              value: formatMoney(aContext, series.expenseTotal, series.currCode),
            ),
            Text(
              '${'finance.net'.tr()}: ${formatMoney(aContext, series.incomeTotal - series.expenseTotal, series.currCode, aIsSigned: true)}',
              style: const TextStyle(color: inkSecondary, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _isTableVisible = !_isTableVisible),
              icon: Icon(_isTableVisible ? AppIcons.chartColumn : AppIcons.table, size: 18),
              label: Text(_isTableVisible ? 'finance.show_chart'.tr() : 'finance.show_table'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_isTableVisible) _buildTable(aContext) else _buildChart(aContext),
      ],
    );
  }

  Widget _buildChart(BuildContext aContext)
  {
    final points = widget.series.points;

    return LayoutBuilder(
      builder: (aLayoutContext, aConstraints)
      {
        final plotWidth = math.max(0.0, aConstraints.maxWidth - _axisWidth);
        final hovered = _hoverIndex == null ? null : points[_hoverIndex!];

        return MouseRegion(
          onHover: (aEvent) => _updateHover(aEvent.localPosition, plotWidth),
          onExit: (_) => setState(() => _hoverIndex = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (aDetails) => _updateHover(aDetails.localPosition, plotWidth),
            onHorizontalDragUpdate: (aDetails) => _updateHover(aDetails.localPosition, plotWidth),
            child: SizedBox(
              height: _chartHeight + _labelHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CashflowPainter(
                        points: points,
                        hoverIndex: _hoverIndex,
                        axisLabel: (aValue) => formatCompact(aContext, aValue),
                        bucketLabel: (aTs) => _bucketLabel(aContext, aTs),
                      ),
                    ),
                  ),
                  if (hovered != null)
                    _buildTooltip(aContext, hovered, plotWidth, aConstraints.maxWidth),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTooltip(BuildContext aContext, CashflowPoint aPoint, double aPlotWidth, double aFullWidth)
  {
    const tooltipWidth = 190.0;
    final slot = aPlotWidth / widget.series.points.length;
    final center = _axisWidth + slot * (_hoverIndex! + 0.5);
    final left = (center + 12 + tooltipWidth > aFullWidth ? center - 12 - tooltipWidth : center + 12)
        .clamp(0.0, math.max(0.0, aFullWidth - tooltipWidth))
        .toDouble();
    final currCode = widget.series.currCode;

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
                Text(_bucketTitle(aContext, aPoint.ts), style: const TextStyle(color: inkSecondary, fontSize: 12)),
                const SizedBox(height: 6),
                _TooltipRow(color: incomeColor, label: 'finance.income'.tr(), value: formatMoney(aContext, aPoint.income, currCode)),
                _TooltipRow(color: expenseColor, label: 'finance.expense'.tr(), value: formatMoney(aContext, aPoint.expense, currCode)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext aContext)
  {
    final rows = widget.series.points.where((aPoint) => aPoint.income != 0 || aPoint.expense != 0).toList().reversed;
    final currCode = widget.series.currCode;

    if (rows.isEmpty)
    {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('common.no_data'.tr(), style: const TextStyle(color: inkMuted)),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: const TextStyle(color: inkSecondary, fontWeight: FontWeight.w600),
        columns: [
          DataColumn(label: Text('finance.period'.tr())),
          DataColumn(label: Text('finance.income'.tr()), numeric: true),
          DataColumn(label: Text('finance.expense'.tr()), numeric: true),
        ],
        rows: rows
            .map((aPoint) => DataRow(cells: [
                  DataCell(Text(_bucketTitle(aContext, aPoint.ts))),
                  DataCell(Text(formatMoney(aContext, aPoint.income, currCode))),
                  DataCell(Text(formatMoney(aContext, aPoint.expense, currCode))),
                ]))
            .toList(),
      ),
    );
  }
}

class _LegendEntry extends StatelessWidget
{
  final Color color;
  final String label;
  final String value;

  const _LegendEntry({required this.color, required this.label, required this.value});

  @override
  Widget build(BuildContext aContext)
  {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text('$label ', style: const TextStyle(color: inkSecondary)),
        Text(value, style: const TextStyle(color: inkPrimary, fontWeight: FontWeight.w600)),
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
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: const TextStyle(color: inkSecondary, fontSize: 13))),
          Text(value, style: const TextStyle(color: inkPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _CashflowPainter extends CustomPainter
{
  final List<CashflowPoint> points;
  final int? hoverIndex;
  final String Function(double) axisLabel;
  final String Function(DateTime) bucketLabel;

  _CashflowPainter({
    required this.points,
    required this.hoverIndex,
    required this.axisLabel,
    required this.bucketLabel,
  });

  double _niceCeil(double aValue)
  {
    if (aValue <= 0)
    {
      return 1;
    }

    final exponent = math.pow(10, (math.log(aValue) / math.ln10).floor()).toDouble();
    final fraction = aValue / exponent;
    final nice = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10;
    return nice * exponent;
  }

  void _paintText(Canvas aCanvas, String aText, Offset aAnchor, {TextAlign aAlign = TextAlign.left, double aMaxWidth = 80})
  {
    final painter = TextPainter(
      text: TextSpan(text: aText, style: const TextStyle(color: inkMuted, fontSize: 11)),
      textDirection: TextDirection.ltr,
      textAlign: aAlign,
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
    const plotLeft = _axisWidth;
    final plotWidth = aSize.width - plotLeft;
    final plotHeight = aSize.height - _labelHeight;
    final maxValue = points.fold<double>(0, (aMax, aPoint) => math.max(aMax, math.max(aPoint.income, aPoint.expense)));
    final scaleMax = _niceCeil(maxValue);
    final baseline = plotHeight / 2;
    final unit = (plotHeight / 2 - 6) / scaleMax;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final fraction in const [1.0, 0.5, -0.5, -1.0])
    {
      final y = baseline - fraction * scaleMax * unit;
      aCanvas.drawLine(Offset(plotLeft, y), Offset(aSize.width, y), gridPaint);
      _paintText(aCanvas, axisLabel(fraction.abs() * scaleMax), Offset(plotLeft - 8, y), aAlign: TextAlign.right, aMaxWidth: _axisWidth - 8);
    }

    if (points.isEmpty || plotWidth <= 0)
    {
      return;
    }

    final slot = plotWidth / points.length;
    final barWidth = math.min(_maxBarWidth, math.max(1.0, slot - 2));
    final radius = Radius.circular(math.min(_barRadius, barWidth / 2));

    if (hoverIndex != null)
    {
      final left = plotLeft + slot * hoverIndex!;
      aCanvas.drawRect(
        Rect.fromLTWH(left, 0, slot, plotHeight),
        Paint()..color = const Color(0x0F111827),
      );
    }

    for (var index = 0; index < points.length; index++)
    {
      final point = points[index];
      final centerX = plotLeft + slot * (index + 0.5);
      final left = centerX - barWidth / 2;

      if (point.income > 0)
      {
        final height = math.max(1.0, point.income * unit);
        aCanvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(left, baseline - height - 1, barWidth, height),
            topLeft: radius,
            topRight: radius,
          ),
          Paint()..color = incomeColor,
        );
      }

      if (point.expense > 0)
      {
        final height = math.max(1.0, point.expense * unit);
        aCanvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(left, baseline + 1, barWidth, height),
            bottomLeft: radius,
            bottomRight: radius,
          ),
          Paint()..color = expenseColor,
        );
      }
    }

    aCanvas.drawLine(
      Offset(plotLeft, baseline),
      Offset(aSize.width, baseline),
      Paint()
        ..color = baselineColor
        ..strokeWidth = 1,
    );

    final labelCount = math.max(1, math.min(points.length, (plotWidth / 72).floor()));
    final step = (points.length / labelCount).ceil();
    for (var index = 0; index < points.length; index += step)
    {
      final centerX = plotLeft + slot * (index + 0.5);
      _paintText(aCanvas, bucketLabel(points[index].ts), Offset(centerX, plotHeight + _labelHeight / 2), aAlign: TextAlign.center, aMaxWidth: 70);
    }
  }

  @override
  bool shouldRepaint(covariant _CashflowPainter aOld) => aOld.points != points || aOld.hoverIndex != hoverIndex;
}
