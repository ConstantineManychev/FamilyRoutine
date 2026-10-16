import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'training_format.dart';

const double _chartHeight = 220;
const double _axisWidth = 44;
const double _plotPadding = 12;
const double _markerRadius = 4;
const double _selectedRadius = 6;
const double _ringWidth = 2;
const double _lineWidth = 2;
const int _tickTarget = 4;

class ExerciseProgressScreen extends ConsumerStatefulWidget
{
  final String exId;
  final String? personId;

  const ExerciseProgressScreen({super.key, required this.exId, this.personId});

  @override
  ConsumerState<ExerciseProgressScreen> createState() => _ExerciseProgressScreenState();
}

class _ExerciseProgressScreenState extends ConsumerState<ExerciseProgressScreen>
{
  ExerciseProgress? _progress;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    setState(() => _error = null);
    try
    {
      final personId = widget.personId;
      final api = ref.read(apiProv);
      final progress = personId == null
          ? await api.getExerciseProgress(widget.exId)
          : await api.getPersonExerciseProgress(personId, widget.exId);
      if (mounted)
      {
        setState(() => _progress = progress);
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _error = aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final progress = _progress;
    if (progress == null)
    {
      return _error != null ? ErrorRetry(error: _error!, onRetry: _load) : const Center(child: CircularProgressIndicator());
    }

    final palette = aContext.palette;
    final points = progress.points.where((aPoint) => aPoint.valueOf(progress.measure) != null).toList();

    return ListView(
      padding: screenPadding(aContext),
      children: [
        ScreenHeader(title: exerciseName(progress.exCode, progress.exName)),
        const SizedBox(height: 4),
        Text('training.progress_measure_${progress.measure.name}'.tr(), style: TextStyle(color: palette.inkSecondary)),
        const SizedBox(height: 16),
        if (points.isEmpty)
          Text('training.progress_empty'.tr(), style: TextStyle(color: palette.inkMuted))
        else ...[
          _StatRow(measure: progress.measure, points: points),
          const SizedBox(height: 16),
          ProgressChart(measure: progress.measure, points: points),
          if (progress.measure == ProgressMeasure.weight) ...[
            const SizedBox(height: 8),
            Text('training.progress_e1rm_hint'.tr(), style: TextStyle(color: palette.inkMuted, fontSize: 12)),
          ],
          const SizedBox(height: 24),
          Text('training.progress_history'.tr(), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final point in points.reversed) _HistoryRow(measure: progress.measure, point: point),
        ],
      ],
    );
  }
}

String progressValueLabel(BuildContext aContext, ProgressMeasure aMeasure, double aValue) => switch (aMeasure)
{
  ProgressMeasure.weight => formatWeight(aContext, aValue),
  ProgressMeasure.reps => 'training.progress_reps_value'.tr(args: [formatNumber(aContext, aValue)]),
  ProgressMeasure.duration => formatClock(aValue.round()),
};

String bestSetLabel(BuildContext aContext, ProgressPoint aPoint)
{
  final weight = aPoint.topWeightKg;
  if (weight != null)
  {
    return '${formatNumber(aContext, weight)} × ${aPoint.topReps ?? 0}';
  }
  if (aPoint.topReps != null)
  {
    return '${aPoint.topReps}';
  }
  final duration = aPoint.bestDurationSec;
  return duration == null ? '—' : formatClock(duration);
}

class _StatRow extends StatelessWidget
{
  final ProgressMeasure measure;
  final List<ProgressPoint> points;

  const _StatRow({required this.measure, required this.points});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final values = points.map((aPoint) => aPoint.valueOf(measure)!).toList();
    final current = values.last;
    final best = values.reduce(math.max);
    final change = current - values.first;
    final sign = change > 0 ? '+' : (change < 0 ? '−' : '');
    final changeColor = change > 0 ? palette.positive : (change < 0 ? palette.warning : palette.inkSecondary);

    Widget tile(String aLabel, String aValue, {Color? aAccent})
    {
      return Container(
        constraints: const BoxConstraints(minWidth: 104),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: palette.surfaceMuted,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(aLabel, style: TextStyle(color: palette.inkSecondary, fontSize: 12)),
            const SizedBox(height: 2),
            Text(
              aValue,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: aAccent ?? palette.inkPrimary),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        tile('training.progress_current'.tr(), progressValueLabel(aContext, measure, current)),
        tile('training.progress_best'.tr(), progressValueLabel(aContext, measure, best)),
        if (values.length > 1)
          tile(
            'training.progress_change'.tr(),
            '$sign${progressValueLabel(aContext, measure, change.abs())}',
            aAccent: changeColor,
          ),
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget
{
  final ProgressMeasure measure;
  final ProgressPoint point;

  const _HistoryRow({required this.measure, required this.point});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final date = DateFormat.yMMMd(aContext.locale.toLanguageTag()).format(point.startedTs);
    final details = [
      'training.progress_best_set'.tr(args: [bestSetLabel(aContext, point)]),
      if (point.volumeKg > 0) 'training.progress_volume'.tr(args: [formatWeight(aContext, point.volumeKg)]),
      if (measure != ProgressMeasure.duration && point.totalReps > 0) 'training.progress_total_reps'.tr(args: ['${point.totalReps}']),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  point.dayName == null ? date : '$date · ${point.dayName}',
                  style: TextStyle(color: palette.inkPrimary, fontWeight: FontWeight.w600),
                ),
                Text(details, style: TextStyle(color: palette.inkSecondary, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            progressValueLabel(aContext, measure, point.valueOf(measure)!),
            style: TextStyle(color: palette.inkPrimary, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

class ProgressChart extends StatefulWidget
{
  final ProgressMeasure measure;
  final List<ProgressPoint> points;

  const ProgressChart({super.key, required this.measure, required this.points});

  @override
  State<ProgressChart> createState() => _ProgressChartState();
}

class _ProgressChartState extends State<ProgressChart>
{
  int? _selected;

  int get _active => (_selected ?? widget.points.length - 1).clamp(0, widget.points.length - 1);

  void _select(double aX, double aWidth)
  {
    final layout = _ChartLayout(widget.points, aWidth);
    var nearest = 0;
    var distance = double.infinity;
    for (var index = 0; index < widget.points.length; index++)
    {
      final gap = (layout.xOf(index) - aX).abs();
      if (gap < distance)
      {
        distance = gap;
        nearest = index;
      }
    }
    if (nearest != _selected)
    {
      setState(() => _selected = nearest);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final point = widget.points[_active];
    final localeTag = aContext.locale.toLanguageTag();
    final dateFormat = DateFormat.MMMd(localeTag);
    final values = widget.points.map((aPoint) => aPoint.valueOf(widget.measure)!).toList();
    final ticks = niceTicks(values.reduce(math.min), values.reduce(math.max));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(DateFormat.yMMMd(localeTag).format(point.startedTs), style: TextStyle(color: palette.inkSecondary)),
            Text(
              progressValueLabel(aContext, widget.measure, point.valueOf(widget.measure)!),
              style: TextStyle(color: palette.inkPrimary, fontWeight: FontWeight.w700, fontSize: 16),
            ),
            Text(
              'training.progress_best_set'.tr(args: [bestSetLabel(aContext, point)]),
              style: TextStyle(color: palette.inkSecondary, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ExcludeSemantics(
          child: SizedBox(
            height: _chartHeight,
            child: LayoutBuilder(
              builder: (_, aConstraints)
              {
                final width = aConstraints.maxWidth;
                return MouseRegion(
                  onHover: (aEvent) => _select(aEvent.localPosition.dx, width),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (aDetails) => _select(aDetails.localPosition.dx, width),
                    onHorizontalDragUpdate: (aDetails) => _select(aDetails.localPosition.dx, width),
                    child: CustomPaint(
                      size: Size(width, _chartHeight),
                      painter: _ProgressPainter(
                        points: widget.points,
                        values: values,
                        ticks: ticks,
                        selected: _active,
                        palette: palette,
                        tickLabel: (aValue) => widget.measure == ProgressMeasure.duration
                            ? formatClock(aValue.round())
                            : NumberFormat.compact(locale: localeTag).format(aValue),
                        textDirection: Directionality.of(aContext),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: _axisWidth, top: 4),
          child: Row(
            children: [
              Text(dateFormat.format(widget.points.first.startedTs), style: TextStyle(color: palette.inkMuted, fontSize: 11)),
              const Spacer(),
              if (widget.points.length > 1)
                Text(dateFormat.format(widget.points.last.startedTs), style: TextStyle(color: palette.inkMuted, fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

List<double> niceTicks(double aMin, double aMax)
{
  var low = aMin;
  var high = aMax;
  if (high - low < 1e-9)
  {
    final pad = math.max(1.0, high.abs() * 0.05);
    low -= pad;
    high += pad;
  }
  final rough = (high - low) / (_tickTarget - 1);
  final magnitude = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
  final step = [1.0, 2.0, 2.5, 5.0, 10.0].map((aFactor) => aFactor * magnitude).firstWhere((aStep) => aStep >= rough);
  final start = (low / step).floor() * step;
  final end = (high / step).ceil() * step;
  return [for (var value = start; value <= end + step / 2; value += step) double.parse(value.toStringAsFixed(6))];
}

class _ChartLayout
{
  final List<ProgressPoint> points;
  final double width;

  _ChartLayout(this.points, this.width);

  double get left => _axisWidth + _plotPadding;

  double get right => width - _plotPadding;

  double xOf(int aIndex)
  {
    if (points.length == 1)
    {
      return (left + right) / 2;
    }
    final first = points.first.startedTs.millisecondsSinceEpoch;
    final span = points.last.startedTs.millisecondsSinceEpoch - first;
    final share = span == 0 ? aIndex / (points.length - 1) : (points[aIndex].startedTs.millisecondsSinceEpoch - first) / span;
    return left + (right - left) * share;
  }
}

class _ProgressPainter extends CustomPainter
{
  final List<ProgressPoint> points;
  final List<double> values;
  final List<double> ticks;
  final int selected;
  final AppPalette palette;
  final String Function(double aValue) tickLabel;
  final TextDirection textDirection;

  _ProgressPainter({
    required this.points,
    required this.values,
    required this.ticks,
    required this.selected,
    required this.palette,
    required this.tickLabel,
    required this.textDirection,
  });

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    final layout = _ChartLayout(points, aSize.width);
    const top = _plotPadding;
    final bottom = aSize.height - _plotPadding;
    final low = ticks.first;
    final high = ticks.last;
    double yOf(double aValue) => bottom - (aValue - low) / (high - low) * (bottom - top);

    final grid = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    for (final tick in ticks)
    {
      final y = yOf(tick);
      aCanvas.drawLine(Offset(_axisWidth, y), Offset(aSize.width, y), grid);
      final label = TextPainter(
        text: TextSpan(text: tickLabel(tick), style: TextStyle(color: palette.inkMuted, fontSize: 11)),
        textDirection: textDirection,
      )..layout(maxWidth: _axisWidth - 6);
      label.paint(aCanvas, Offset(_axisWidth - 6 - label.width, y - label.height / 2));
    }

    final color = palette.seriesAt(0);
    final positions = [for (var index = 0; index < points.length; index++) Offset(layout.xOf(index), yOf(values[index]))];

    final crosshair = Paint()
      ..color = palette.baseline
      ..strokeWidth = 1;
    aCanvas.drawLine(Offset(positions[selected].dx, top), Offset(positions[selected].dx, bottom), crosshair);

    if (positions.length > 1)
    {
      final path = Path()..moveTo(positions.first.dx, positions.first.dy);
      for (final position in positions.skip(1))
      {
        path.lineTo(position.dx, position.dy);
      }
      final area = Path.from(path)
        ..lineTo(positions.last.dx, bottom)
        ..lineTo(positions.first.dx, bottom)
        ..close();
      aCanvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.1));
      aCanvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = _lineWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    for (var index = 0; index < positions.length; index++)
    {
      final radius = index == selected ? _selectedRadius : _markerRadius;
      aCanvas.drawCircle(positions[index], radius + _ringWidth, Paint()..color = palette.surface);
      aCanvas.drawCircle(positions[index], radius, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _ProgressPainter aOldDelegate) =>
      aOldDelegate.selected != selected || aOldDelegate.points != points || aOldDelegate.palette != palette;
}
