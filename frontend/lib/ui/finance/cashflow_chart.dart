import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/money.dart';

const double _chartHeight = 220;
const double _axisWidth = 52;
const double _labelHeight = 22;
const double _maxBarWidth = 24;
const double _barRadius = 4;
const int _visibleColumns = 7;
const double _compactWidth = 600;
const double _minColumnWidth = 22;
const double _labelSpacing = 56;

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

void _paintText(Canvas aCanvas, AppPalette aPalette, String aText, Offset aAnchor, {TextAlign aAlign = TextAlign.left, double aMaxWidth = 80})
{
  final painter = TextPainter(
    text: TextSpan(text: aText, style: TextStyle(color: aPalette.inkMuted, fontSize: 11)),
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
  final _scroll = ScrollController();
  int? _selected;
  bool _isTableVisible = false;
  bool _isPositioned = false;

  @override
  void dispose()
  {
    _scroll.dispose();
    super.dispose();
  }

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

  int? get _readoutIndex
  {
    final points = widget.series.points;
    if (_selected != null && _selected! < points.length)
    {
      return _selected;
    }
    for (var index = points.length - 1; index >= 0; index--)
    {
      if (points[index].income != 0 || points[index].expense != 0)
      {
        return index;
      }
    }
    return points.isEmpty ? null : points.length - 1;
  }

  void _select(double aX, double aColumnWidth)
  {
    final points = widget.series.points;
    final index = (aX / aColumnWidth).floor();
    final next = index >= 0 && index < points.length ? index : null;
    if (next != null && next != _selected)
    {
      setState(() => _selected = next);
    }
  }

  void _scrollToLatest()
  {
    if (_isPositioned)
    {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_)
    {
      if (mounted && _scroll.hasClients)
      {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
        _isPositioned = true;
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    final series = widget.series;
    final palette = aContext.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _LegendEntry(color: palette.income, label: 'finance.income'.tr(), value: formatMoney(aContext, series.incomeTotal, series.currCode)),
            _LegendEntry(color: palette.expense, label: 'finance.expense'.tr(), value: formatMoney(aContext, series.expenseTotal, series.currCode)),
            Text(
              '${'finance.net'.tr()}: ${formatMoney(aContext, series.incomeTotal - series.expenseTotal, series.currCode, aIsSigned: true)}',
              style: TextStyle(color: palette.inkSecondary, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _isTableVisible = !_isTableVisible),
              icon: Icon(_isTableVisible ? AppIcons.chartColumn : AppIcons.table, size: 18),
              label: Text(_isTableVisible ? 'finance.show_chart'.tr() : 'finance.show_table'.tr()),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_isTableVisible) _buildTable(aContext) else ...[
          _buildReadout(aContext),
          const SizedBox(height: 8),
          _buildChart(aContext),
        ],
      ],
    );
  }

  Widget _buildReadout(BuildContext aContext)
  {
    final index = _readoutIndex;
    final palette = aContext.palette;
    if (index == null)
    {
      return const SizedBox(height: 20);
    }
    final point = widget.series.points[index];
    final currCode = widget.series.currCode;

    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(_bucketTitle(aContext, point.ts), style: TextStyle(color: palette.inkPrimary, fontWeight: FontWeight.w600)),
        _LegendEntry(color: palette.income, label: '', value: formatMoney(aContext, point.income, currCode)),
        _LegendEntry(color: palette.expense, label: '', value: formatMoney(aContext, point.expense, currCode)),
      ],
    );
  }

  Widget _buildChart(BuildContext aContext)
  {
    final points = widget.series.points;
    final palette = aContext.palette;
    final isCompact = MediaQuery.sizeOf(aContext).width < _compactWidth;
    final maxValue = points.fold<double>(0, (aMax, aPoint) => math.max(aMax, math.max(aPoint.income, aPoint.expense)));
    final scaleMax = _niceCeil(maxValue);

    return SizedBox(
      height: _chartHeight + _labelHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _axisWidth,
            child: CustomPaint(
              painter: _AxisPainter(palette: palette, scaleMax: scaleMax, axisLabel: (aValue) => formatCompact(aContext, aValue)),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (_, aConstraints)
              {
                final viewport = aConstraints.maxWidth;
                final count = math.max(1, points.length);
                final columnWidth = count <= _visibleColumns
                    ? viewport / count
                    : isCompact
                        ? viewport / _visibleColumns
                        : math.max(viewport / count, _minColumnWidth);
                final contentWidth = math.max(viewport, columnWidth * count);
                final isScrollable = contentWidth > viewport + 0.5;
                if (isScrollable)
                {
                  _scrollToLatest();
                }

                return ScrollConfiguration(
                  behavior: ScrollConfiguration.of(aContext).copyWith(
                    dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse, PointerDeviceKind.trackpad, PointerDeviceKind.stylus},
                    scrollbars: false,
                  ),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    physics: isScrollable
                        ? const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())
                        : const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: contentWidth,
                      child: MouseRegion(
                        onHover: (aEvent) => _select(aEvent.localPosition.dx, columnWidth),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (aDetails) => _select(aDetails.localPosition.dx, columnWidth),
                          child: CustomPaint(
                            painter: _BarsPainter(
                              palette: palette,
                              points: points,
                              columnWidth: columnWidth,
                              scaleMax: scaleMax,
                              selected: _readoutIndex,
                              bucketLabel: (aTs) => _bucketLabel(aContext, aTs),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
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
        child: Text('common.no_data'.tr(), style: TextStyle(color: aContext.palette.inkMuted)),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingTextStyle: TextStyle(color: aContext.palette.inkSecondary, fontWeight: FontWeight.w600),
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
        if (label.isNotEmpty) Text('$label ', style: TextStyle(color: aContext.palette.inkSecondary)),
        Text(value, style: TextStyle(color: aContext.palette.inkPrimary, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _AxisPainter extends CustomPainter
{
  final AppPalette palette;
  final double scaleMax;
  final String Function(double) axisLabel;

  _AxisPainter({required this.palette, required this.scaleMax, required this.axisLabel});

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    final plotHeight = aSize.height - _labelHeight;
    final baseline = plotHeight / 2;
    final unit = (plotHeight / 2 - 6) / scaleMax;
    for (final fraction in const [1.0, 0.5, -0.5, -1.0])
    {
      final y = baseline - fraction * scaleMax * unit;
      _paintText(aCanvas, palette, axisLabel(fraction.abs() * scaleMax), Offset(aSize.width - 8, y), aAlign: TextAlign.right, aMaxWidth: aSize.width - 8);
    }
  }

  @override
  bool shouldRepaint(covariant _AxisPainter aOld) => aOld.scaleMax != scaleMax || aOld.palette != palette;
}

class _BarsPainter extends CustomPainter
{
  final AppPalette palette;
  final List<CashflowPoint> points;
  final double columnWidth;
  final double scaleMax;
  final int? selected;
  final String Function(DateTime) bucketLabel;

  _BarsPainter({
    required this.palette,
    required this.points,
    required this.columnWidth,
    required this.scaleMax,
    required this.selected,
    required this.bucketLabel,
  });

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    final plotHeight = aSize.height - _labelHeight;
    final baseline = plotHeight / 2;
    final unit = (plotHeight / 2 - 6) / scaleMax;

    final gridPaint = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    for (final fraction in const [1.0, 0.5, -0.5, -1.0])
    {
      final y = baseline - fraction * scaleMax * unit;
      aCanvas.drawLine(Offset(0, y), Offset(aSize.width, y), gridPaint);
    }

    if (points.isEmpty)
    {
      return;
    }

    final barWidth = math.min(_maxBarWidth, math.max(1.0, columnWidth - 6));
    final radius = Radius.circular(math.min(_barRadius, barWidth / 2));

    if (selected != null)
    {
      aCanvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(columnWidth * selected!, 0, columnWidth, plotHeight), const Radius.circular(6)),
        Paint()..color = palette.hover,
      );
    }

    for (var index = 0; index < points.length; index++)
    {
      final point = points[index];
      final left = columnWidth * (index + 0.5) - barWidth / 2;

      if (point.income > 0)
      {
        final height = math.max(1.0, point.income * unit);
        aCanvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(left, baseline - height - 1, barWidth, height), topLeft: radius, topRight: radius),
          Paint()..color = palette.income,
        );
      }

      if (point.expense > 0)
      {
        final height = math.max(1.0, point.expense * unit);
        aCanvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(left, baseline + 1, barWidth, height), bottomLeft: radius, bottomRight: radius),
          Paint()..color = palette.expense,
        );
      }
    }

    aCanvas.drawLine(
      Offset(0, baseline),
      Offset(aSize.width, baseline),
      Paint()
        ..color = palette.baseline
        ..strokeWidth = 1,
    );

    final step = math.max(1, (_labelSpacing / columnWidth).ceil());
    for (var index = points.length - 1; index >= 0; index -= step)
    {
      final centerX = columnWidth * (index + 0.5);
      _paintText(aCanvas, palette, bucketLabel(points[index].ts), Offset(centerX, plotHeight + _labelHeight / 2), aAlign: TextAlign.center, aMaxWidth: math.max(columnWidth * step - 4, 40));
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter aOld) =>
      aOld.points != points || aOld.selected != selected || aOld.columnWidth != columnWidth || aOld.palette != palette;
}
