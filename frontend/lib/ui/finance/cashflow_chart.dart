import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/money.dart';
import '../common/snap_tab_view.dart';

const double _chartHeight = 220;
const double _axisWidth = 52;
const double _labelHeight = 22;
const double _maxBarWidth = 24;
const double _barRadius = 4;
const int _visibleColumns = 7;
const double _compactWidth = 600;
const double _minColumnWidth = 22;
const double _labelSpacing = 56;
const double _plotPadding = 6;
const double _lineWidth = 2.5;
const double _dotRadius = 3.5;
const List<double> _gridFractions = [1.0, 0.5, -0.5, -1.0];

double _niceCeil(double aValue)
{
  if (aValue <= 0)
  {
    return 0;
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

List<double> runningBalance(List<CashflowPoint> aPoints)
{
  var balance = 0.0;
  return [
    for (final point in aPoints) balance += point.income - point.expense,
  ];
}

class ChartScale
{
  final double top;
  final double bottom;

  const ChartScale(this.top, this.bottom);

  factory ChartScale.of(double aMax, double aMin)
  {
    final top = _niceCeil(math.max(0, aMax));
    final bottom = _niceCeil(math.max(0, -aMin));
    return top == 0 && bottom == 0 ? const ChartScale(1, 1) : ChartScale(top, bottom);
  }

  double get span => top + bottom;

  double yOf(double aValue, double aPlotHeight) => _plotPadding + (top - aValue) / span * (aPlotHeight - 2 * _plotPadding);

  List<double> get ticks => [
        for (final fraction in _gridFractions)
          if (fraction > 0 && top > 0) top * fraction else if (fraction < 0 && bottom > 0) bottom * fraction,
      ];

  bool isSameAs(ChartScale aOther) => aOther.top == top && aOther.bottom == bottom;
}

class CashflowChart extends StatefulWidget
{
  final CashflowSeries series;
  final StatsBucket bucket;
  final ChartKind kind;
  final void Function(DateTime aFrom, DateTime aTo)? onOpenPeriod;

  const CashflowChart({super.key, required this.series, required this.bucket, this.kind = ChartKind.bars, this.onOpenPeriod});

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

  bool get _isBalance => widget.kind == ChartKind.balance;

  String _bucketLabel(BuildContext aContext, DateTime aTs)
  {
    final locale = aContext.locale.toLanguageTag();
    return switch (widget.bucket)
    {
      StatsBucket.hour => DateFormat.Hm(locale).format(aTs),
      StatsBucket.month => DateFormat.MMM(locale).format(aTs),
      _ => DateFormat.MMMd(locale).format(aTs),
    };
  }

  String _bucketTitle(BuildContext aContext, DateTime aTs)
  {
    final locale = aContext.locale.toLanguageTag();
    return switch (widget.bucket)
    {
      StatsBucket.hour => DateFormat.MMMd(locale).add_Hm().format(aTs),
      StatsBucket.day => DateFormat.yMMMEd(locale).format(aTs),
      StatsBucket.week =>
        '${DateFormat.MMMd(locale).format(aTs)} – ${DateFormat.yMMMd(locale).format(widget.bucket.endOf(aTs).subtract(const Duration(days: 1)))}',
      StatsBucket.month => DateFormat.yMMMM(locale).format(aTs),
    };
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

  int? _indexAt(double aX, double aColumnWidth)
  {
    final index = (aX / aColumnWidth).floor();
    return index >= 0 && index < widget.series.points.length ? index : null;
  }

  void _select(double aX, double aColumnWidth)
  {
    final next = _indexAt(aX, aColumnWidth);
    if (next != null && next != _selected)
    {
      setState(() => _selected = next);
    }
  }

  void _open(int aIndex)
  {
    final open = widget.onOpenPeriod;
    if (open == null)
    {
      return;
    }
    final start = widget.series.points[aIndex].ts.toLocal();
    open(start, widget.bucket.endOf(start));
  }

  void _tap(double aX, double aColumnWidth)
  {
    final index = _indexAt(aX, aColumnWidth);
    if (index == null)
    {
      return;
    }
    setState(() => _selected = index);
    _open(index);
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
          if (widget.onOpenPeriod != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('finance.chart_tap_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            ),
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
        if (_isBalance)
          _LegendEntry(
            color: aContext.colors.primary,
            label: 'finance.balance_at'.tr(),
            value: formatMoney(aContext, runningBalance(widget.series.points)[index], currCode, aIsSigned: true),
          ),
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
    final balances = runningBalance(points);
    final ChartScale scale;
    if (_isBalance)
    {
      scale = ChartScale.of(balances.fold<double>(0, math.max), balances.fold<double>(0, math.min));
    }
    else
    {
      final maxValue = points.fold<double>(0, (aMax, aPoint) => math.max(aMax, math.max(aPoint.income, aPoint.expense)));
      final symmetric = _niceCeil(maxValue);
      scale = symmetric == 0 ? const ChartScale(1, 1) : ChartScale(symmetric, symmetric);
    }

    return SizedBox(
      height: _chartHeight + _labelHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _axisWidth,
            child: CustomPaint(
              painter: _AxisPainter(
                palette: palette,
                scale: scale,
                axisLabel: (aValue) => _isBalance && aValue < 0 ? '−${formatCompact(aContext, -aValue)}' : formatCompact(aContext, aValue.abs()),
              ),
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
                  child: HorizontalScrollZone(
                    isEnabled: isScrollable,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      physics: isScrollable
                          ? const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())
                          : const NeverScrollableScrollPhysics(),
                      child: SizedBox(
                        width: contentWidth,
                        child: MouseRegion(
                          cursor: widget.onOpenPeriod == null ? MouseCursor.defer : SystemMouseCursors.click,
                          onHover: (aEvent) => _select(aEvent.localPosition.dx, columnWidth),
                          child: GestureDetector(
                            key: const ValueKey('cashflow.plot'),
                            behavior: HitTestBehavior.opaque,
                            excludeFromSemantics: true,
                            onTapUp: (aDetails) => _tap(aDetails.localPosition.dx, columnWidth),
                            onLongPressStart: (aDetails) => _select(aDetails.localPosition.dx, columnWidth),
                            onLongPressMoveUpdate: (aDetails) => _select(aDetails.localPosition.dx, columnWidth),
                            child: CustomPaint(
                              painter: _isBalance
                                  ? _BalancePainter(
                                      palette: palette,
                                      line: aContext.colors.primary,
                                      points: points,
                                      balances: balances,
                                      columnWidth: columnWidth,
                                      scale: scale,
                                      selected: _readoutIndex,
                                      bucketLabel: (aTs) => _bucketLabel(aContext, aTs),
                                    )
                                  : _BarsPainter(
                                      palette: palette,
                                      points: points,
                                      columnWidth: columnWidth,
                                      scale: scale,
                                      selected: _readoutIndex,
                                      bucketLabel: (aTs) => _bucketLabel(aContext, aTs),
                                    ),
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
    final points = widget.series.points;
    final balances = runningBalance(points);
    final indexes = [
      for (var index = points.length - 1; index >= 0; index--)
        if (points[index].income != 0 || points[index].expense != 0) index,
    ];
    final currCode = widget.series.currCode;

    if (indexes.isEmpty)
    {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text('common.no_data'.tr(), style: TextStyle(color: aContext.palette.inkMuted)),
      );
    }

    return HorizontalScrollZone(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          showCheckboxColumn: false,
          headingTextStyle: TextStyle(color: aContext.palette.inkSecondary, fontWeight: FontWeight.w600),
          columns: [
            DataColumn(label: Text('finance.period'.tr())),
            DataColumn(label: Text('finance.income'.tr()), numeric: true),
            DataColumn(label: Text('finance.expense'.tr()), numeric: true),
            if (_isBalance) DataColumn(label: Text('finance.balance_at'.tr()), numeric: true),
          ],
          rows: [
            for (final index in indexes)
              DataRow(
                onSelectChanged: widget.onOpenPeriod == null ? null : (_) => _open(index),
                cells: [
                  DataCell(Text(_bucketTitle(aContext, points[index].ts))),
                  DataCell(Text(formatMoney(aContext, points[index].income, currCode))),
                  DataCell(Text(formatMoney(aContext, points[index].expense, currCode))),
                  if (_isBalance) DataCell(Text(formatMoney(aContext, balances[index], currCode, aIsSigned: true))),
                ],
              ),
          ],
        ),
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
  final ChartScale scale;
  final String Function(double) axisLabel;

  _AxisPainter({required this.palette, required this.scale, required this.axisLabel});

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    final plotHeight = aSize.height - _labelHeight;
    for (final tick in scale.ticks)
    {
      _paintText(aCanvas, palette, axisLabel(tick), Offset(aSize.width - 8, scale.yOf(tick, plotHeight)), aAlign: TextAlign.right, aMaxWidth: aSize.width - 8);
    }
  }

  @override
  bool shouldRepaint(covariant _AxisPainter aOld) => !aOld.scale.isSameAs(scale) || aOld.palette != palette;
}

abstract class _PlotPainter extends CustomPainter
{
  final AppPalette palette;
  final List<CashflowPoint> points;
  final double columnWidth;
  final ChartScale scale;
  final int? selected;
  final String Function(DateTime) bucketLabel;

  _PlotPainter({
    required this.palette,
    required this.points,
    required this.columnWidth,
    required this.scale,
    required this.selected,
    required this.bucketLabel,
  });

  void paintFrame(Canvas aCanvas, Size aSize)
  {
    final plotHeight = aSize.height - _labelHeight;
    final gridPaint = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    for (final tick in scale.ticks)
    {
      final y = scale.yOf(tick, plotHeight);
      aCanvas.drawLine(Offset(0, y), Offset(aSize.width, y), gridPaint);
    }
    if (selected != null && points.isNotEmpty)
    {
      aCanvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(columnWidth * selected!, 0, columnWidth, plotHeight), const Radius.circular(6)),
        Paint()..color = palette.hover,
      );
    }
  }

  void paintBaseline(Canvas aCanvas, Size aSize)
  {
    final y = scale.yOf(0, aSize.height - _labelHeight);
    aCanvas.drawLine(
      Offset(0, y),
      Offset(aSize.width, y),
      Paint()
        ..color = palette.baseline
        ..strokeWidth = 1,
    );
  }

  void paintLabels(Canvas aCanvas, Size aSize)
  {
    final plotHeight = aSize.height - _labelHeight;
    final step = math.max(1, (_labelSpacing / columnWidth).ceil());
    for (var index = points.length - 1; index >= 0; index -= step)
    {
      final centerX = columnWidth * (index + 0.5);
      _paintText(aCanvas, palette, bucketLabel(points[index].ts), Offset(centerX, plotHeight + _labelHeight / 2), aAlign: TextAlign.center, aMaxWidth: math.max(columnWidth * step - 4, 40));
    }
  }

  @override
  bool shouldRepaint(covariant _PlotPainter aOld) =>
      aOld.points != points || aOld.selected != selected || aOld.columnWidth != columnWidth || aOld.palette != palette || !aOld.scale.isSameAs(scale);
}

class _BarsPainter extends _PlotPainter
{
  _BarsPainter({
    required super.palette,
    required super.points,
    required super.columnWidth,
    required super.scale,
    required super.selected,
    required super.bucketLabel,
  });

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    paintFrame(aCanvas, aSize);
    final plotHeight = aSize.height - _labelHeight;
    final baseline = scale.yOf(0, plotHeight);
    final barWidth = math.min(_maxBarWidth, math.max(1.0, columnWidth - 6));
    final radius = Radius.circular(math.min(_barRadius, barWidth / 2));

    for (var index = 0; index < points.length; index++)
    {
      final point = points[index];
      final left = columnWidth * (index + 0.5) - barWidth / 2;

      if (point.income > 0)
      {
        final height = math.max(1.0, baseline - scale.yOf(point.income, plotHeight));
        aCanvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(left, baseline - height - 1, barWidth, height), topLeft: radius, topRight: radius),
          Paint()..color = palette.income,
        );
      }

      if (point.expense > 0)
      {
        final height = math.max(1.0, scale.yOf(-point.expense, plotHeight) - baseline);
        aCanvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(left, baseline + 1, barWidth, height), bottomLeft: radius, bottomRight: radius),
          Paint()..color = palette.expense,
        );
      }
    }

    paintBaseline(aCanvas, aSize);
    paintLabels(aCanvas, aSize);
  }
}

class _BalancePainter extends _PlotPainter
{
  final Color line;
  final List<double> balances;

  _BalancePainter({
    required super.palette,
    required this.line,
    required super.points,
    required this.balances,
    required super.columnWidth,
    required super.scale,
    required super.selected,
    required super.bucketLabel,
  });

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    paintFrame(aCanvas, aSize);
    paintBaseline(aCanvas, aSize);
    final plotHeight = aSize.height - _labelHeight;
    if (balances.isNotEmpty)
    {
      final offsets = [
        for (var index = 0; index < balances.length; index++) Offset(columnWidth * (index + 0.5), scale.yOf(balances[index], plotHeight)),
      ];
      final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
      for (final offset in offsets.skip(1))
      {
        path.lineTo(offset.dx, offset.dy);
      }
      aCanvas.drawPath(
        path,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = _lineWidth
          ..strokeJoin = StrokeJoin.round,
      );
      for (var index = 0; index < offsets.length; index++)
      {
        final point = points[index];
        if (point.income == 0 && point.expense == 0 && index != selected)
        {
          continue;
        }
        final isUp = point.income >= point.expense;
        aCanvas.drawCircle(offsets[index], index == selected ? _dotRadius + 1.5 : _dotRadius, Paint()..color = isUp ? palette.income : palette.expense);
      }
    }
    paintLabels(aCanvas, aSize);
  }

  @override
  bool shouldRepaint(covariant _BalancePainter aOld) => super.shouldRepaint(aOld) || aOld.line != line || aOld.balances != balances;
}
