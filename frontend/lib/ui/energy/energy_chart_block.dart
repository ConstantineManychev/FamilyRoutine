import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/person_switcher.dart';
import '../nutrition/nutrition_format.dart' show formatAmount, formatKcal, nutritionRevisionProv;
import '../planner/planner_common.dart';
import '../routine/routine_style.dart';
import '../training/training_revision.dart';

const double _chartHeight = 220;
const double _axisWidth = 48;
const double _labelHeight = 20;
const double _tooltipWidth = 200;
const double _lineWidth = 2;
const double _myLineWidth = 3;
const double _minSpan = 500;
const Duration _refreshInterval = Duration(minutes: 5);

double? energyAt(List<EnergyPoint> aPoints, DateTime aMoment)
{
  if (aPoints.isEmpty || aMoment.isBefore(aPoints.first.ts) || aMoment.isAfter(aPoints.last.ts))
  {
    return null;
  }
  for (var index = aPoints.length - 1; index >= 0; index--)
  {
    final point = aPoints[index];
    if (point.ts.isAfter(aMoment))
    {
      continue;
    }
    if (index == aPoints.length - 1 || point.ts.isAtSameMomentAs(aMoment))
    {
      return point.kcal;
    }
    final next = aPoints[index + 1];
    final span = next.ts.difference(point.ts).inMilliseconds;
    if (span <= 0)
    {
      return next.kcal;
    }
    final share = aMoment.difference(point.ts).inMilliseconds / span;
    return point.kcal + (next.kcal - point.kcal) * share;
  }
  return null;
}

String formatSignedKcal(BuildContext aContext, num aValue)
{
  final text = formatKcal(aContext, aValue.abs().toDouble());
  return aValue > 0 ? '+$text' : (aValue < 0 ? '−$text' : text);
}

class EnergyChartBlock extends ConsumerStatefulWidget
{
  const EnergyChartBlock({super.key});

  @override
  ConsumerState<EnergyChartBlock> createState() => _EnergyChartBlockState();
}

class _EnergyChartBlockState extends ConsumerState<EnergyChartBlock>
{
  DateTime _date = dayOnly(DateTime.now());
  EnergyDay? _day;
  Object? _error;
  Timer? _timer;
  int _request = 0;
  final Set<String> _hidden = {};

  bool get _isToday => _date == dayOnly(DateTime.now());

  @override
  void initState()
  {
    super.initState();
    _load();
    _timer = Timer.periodic(_refreshInterval, (_)
    {
      if (mounted && _isToday)
      {
        _load();
      }
    });
  }

  @override
  void dispose()
  {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async
  {
    final request = ++_request;
    try
    {
      final day = await ref.read(apiProv).getEnergyDay(_date);
      if (mounted && request == _request)
      {
        setState(()
        {
          _day = day;
          _error = null;
        });
      }
    }
    catch (aError)
    {
      if (mounted && request == _request)
      {
        setState(() => _error = aError);
      }
    }
  }

  void _shift(int aDays)
  {
    final next = dayOnly(_date.add(Duration(days: aDays, hours: 12)));
    if (next.isAfter(dayOnly(DateTime.now())))
    {
      return;
    }
    setState(()
    {
      _date = next;
      _day = null;
      _error = null;
    });
    _load();
  }

  void _toggle(String aPersonId)
  {
    setState(()
    {
      if (!_hidden.remove(aPersonId))
      {
        _hidden.add(aPersonId);
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(nutritionRevisionProv, (_, __) => _load());
    ref.listen<int>(trainingRevisionProv, (_, __) => _load());
    ref.listen<int>(routineRevisionProv, (_, __) => _load());
    ref.listen<int>(plannerRevisionProv, (_, __) => _load());
    final day = _day;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (day == null)
    {
      content = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    }
    else if (day.people.every((aPerson) => aPerson.points.isEmpty))
    {
      content = BlockEmpty('energy.empty'.tr());
    }
    else
    {
      content = Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EnergyChart(day: day, hidden: _hidden),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < day.people.length; index++)
                  _LegendChip(
                    person: day.people[index],
                    color: personColor(aContext, index),
                    isHidden: _hidden.contains(day.people[index].personId),
                    onTap: () => _toggle(day.people[index].personId),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text('energy.hint'.tr(), style: TextStyle(fontSize: 12, color: aContext.palette.inkMuted)),
          ],
        ),
      );
    }

    return BlockCard(
      title: 'energy.title'.tr(),
      actions: [
        IconButton(
          tooltip: 'routine.prev_day'.tr(),
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.chevronLeft, size: 18),
          onPressed: () => _shift(-1),
        ),
        Text(
          _isToday ? 'routine.today'.tr() : DateFormat.MMMd(aContext.locale.toLanguageTag()).format(_date),
          style: TextStyle(fontWeight: FontWeight.w600, color: aContext.palette.inkSecondary),
        ),
        IconButton(
          tooltip: 'routine.next_day'.tr(),
          visualDensity: VisualDensity.compact,
          icon: const Icon(AppIcons.chevronRight, size: 18),
          onPressed: _isToday ? null : () => _shift(1),
        ),
      ],
      child: content,
    );
  }
}

class _LegendChip extends StatelessWidget
{
  final EnergyPerson person;
  final Color color;
  final bool isHidden;
  final VoidCallback onTap;

  const _LegendChip({required this.person, required this.color, required this.isHidden, required this.onTap});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final name = person.isMe ? 'people.me'.tr() : person.fullName;
    final details = [
      'energy.eaten'.tr(args: [formatKcal(aContext, person.eaten.toDouble())]),
      person.dailyBurn == null
          ? 'energy.no_norm'.tr()
          : 'energy.burned'.tr(args: [formatKcal(aContext, (person.burnedBase + person.burnedWorkouts).toDouble())]),
      if (person.burnedWorkouts > 0) 'energy.workouts'.tr(args: [formatKcal(aContext, person.burnedWorkouts.toDouble())]),
    ].join(' · ');

    return Opacity(
      opacity: isHidden ? 0.45 : 1,
      child: Material(
        color: palette.surfaceMuted,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: ValueKey('energy.legend.${person.personId}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 12, height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
                            TextSpan(
                              text: '  ${formatSignedKcal(aContext, person.balance)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: person.balance > 0 ? palette.warning : palette.positive,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(details, style: TextStyle(fontSize: 11, color: palette.inkSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EnergyChart extends StatefulWidget
{
  final EnergyDay day;
  final Set<String> hidden;

  const EnergyChart({super.key, required this.day, this.hidden = const {}});

  @override
  State<EnergyChart> createState() => _EnergyChartState();
}

class _EnergyChartState extends State<EnergyChart>
{
  DateTime? _cursor;

  List<int> get _visible => [
        for (var index = 0; index < widget.day.people.length; index++)
          if (!widget.hidden.contains(widget.day.people[index].personId) && widget.day.people[index].points.isNotEmpty) index,
      ];

  void _point(Offset aPosition, Size aSize)
  {
    final layout = _EnergyLayout(widget.day, _visible, aSize);
    setState(() => _cursor = layout.tsOf(aPosition.dx));
  }

  @override
  Widget build(BuildContext aContext)
  {
    return LayoutBuilder(
      builder: (_, aConstraints)
      {
        final size = Size(aConstraints.maxWidth, _chartHeight + _labelHeight);
        final visible = _visible;
        final layout = _EnergyLayout(widget.day, visible, size);
        final colors = [for (var index = 0; index < widget.day.people.length; index++) personColor(aContext, index)];
        final cursor = _cursor;

        return MouseRegion(
          onHover: (aEvent) => _point(aEvent.localPosition, size),
          onExit: (_) => setState(() => _cursor = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (aDetails) => _point(aDetails.localPosition, size),
            onLongPressMoveUpdate: (aDetails) => _point(aDetails.localPosition, size),
            onLongPressEnd: (_) => setState(() => _cursor = null),
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      key: const ValueKey('energy.chart'),
                      painter: _EnergyPainter(
                        layout: layout,
                        people: widget.day.people,
                        visible: visible,
                        colors: colors,
                        palette: aContext.palette,
                        cursor: cursor,
                        valueLabel: (aValue) => formatAmount(aContext, aValue, aDigits: 0),
                      ),
                    ),
                  ),
                  if (cursor != null) _buildTooltip(aContext, layout, visible, colors, cursor),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTooltip(BuildContext aContext, _EnergyLayout aLayout, List<int> aVisible, List<Color> aColors, DateTime aCursor)
  {
    final rows = [
      for (final index in aVisible)
        if (energyAt(widget.day.people[index].points, aCursor) != null)
          (index, energyAt(widget.day.people[index].points, aCursor)!),
    ];
    if (rows.isEmpty)
    {
      return const SizedBox.shrink();
    }
    final x = aLayout.xOf(aCursor);
    final width = aLayout.size.width;
    final left = (x + 12 + _tooltipWidth > width ? x - 12 - _tooltipWidth : x + 12)
        .clamp(0.0, math.max(0.0, width - _tooltipWidth))
        .toDouble();

    return Positioned(
      left: left,
      top: 4,
      width: _tooltipWidth,
      child: IgnorePointer(
        child: Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(8),
          color: aContext.colors.surface,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatClock(aContext, aCursor.toLocal()), style: TextStyle(fontSize: 12, color: aContext.palette.inkSecondary)),
                const SizedBox(height: 6),
                for (final (index, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1),
                    child: Row(
                      children: [
                        Container(width: 10, height: 3, color: aColors[index]),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            widget.day.people[index].isMe ? 'people.me'.tr() : widget.day.people[index].firstName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        Text(formatSignedKcal(aContext, value.round()), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EnergyLayout
{
  final DateTime start;
  final DateTime end;
  final double low;
  final double high;
  final Size size;

  factory _EnergyLayout(EnergyDay aDay, List<int> aVisible, Size aSize)
  {
    final values = [
      0.0,
      for (final index in aVisible)
        for (final point in aDay.people[index].points) point.kcal,
    ];
    var low = values.reduce(math.min);
    var high = values.reduce(math.max);
    if (high - low < _minSpan)
    {
      final grow = (_minSpan - (high - low)) / 2;
      low -= grow;
      high += grow;
    }
    final padding = (high - low) * 0.08;
    return _EnergyLayout._(aDay.dayStart, aDay.dayEnd, low - padding, high + padding, aSize);
  }

  const _EnergyLayout._(this.start, this.end, this.low, this.high, this.size);

  double get plotLeft => _axisWidth;

  double get plotRight => size.width - 8;

  double get plotHeight => size.height - _labelHeight;

  double xOf(DateTime aTs)
  {
    final total = end.difference(start).inSeconds;
    final share = total <= 0 ? 0.0 : aTs.difference(start).inSeconds / total;
    return plotLeft + (plotRight - plotLeft) * share.clamp(0.0, 1.0);
  }

  double yOf(double aValue) => plotHeight - (aValue - low) / (high - low) * plotHeight;

  DateTime tsOf(double aX)
  {
    final share = ((aX - plotLeft) / math.max(1.0, plotRight - plotLeft)).clamp(0.0, 1.0);
    return start.add(Duration(seconds: (end.difference(start).inSeconds * share).round()));
  }
}

class _EnergyPainter extends CustomPainter
{
  final _EnergyLayout layout;
  final List<EnergyPerson> people;
  final List<int> visible;
  final List<Color> colors;
  final AppPalette palette;
  final DateTime? cursor;
  final String Function(double) valueLabel;

  _EnergyPainter({
    required this.layout,
    required this.people,
    required this.visible,
    required this.colors,
    required this.palette,
    required this.cursor,
    required this.valueLabel,
  });

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    final grid = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    final baseline = Paint()
      ..color = palette.baseline
      ..strokeWidth = 1.5;
    final step = _niceStep((layout.high - layout.low) / 4);
    for (var value = (layout.low / step).ceil() * step; value <= layout.high; value += step)
    {
      final y = layout.yOf(value);
      aCanvas.drawLine(Offset(layout.plotLeft, y), Offset(layout.plotRight, y), value.abs() < 1e-6 ? baseline : grid);
      _text(aCanvas, valueLabel(value), Offset(layout.plotLeft - 6, y), aAlignRight: true);
    }

    final localStart = layout.start.toLocal();
    final hours = (layout.end.difference(layout.start).inMinutes / 60).round();
    final hourStep = aSize.width >= 640 ? 3 : 6;
    for (var hour = 0; hour <= hours; hour += hourStep)
    {
      final ts = layout.start.add(Duration(hours: hour));
      final x = layout.xOf(ts);
      aCanvas.drawLine(Offset(x, 0), Offset(x, layout.plotHeight), grid);
      final label = '${((localStart.hour + hour) % 24).toString().padLeft(2, '0')}:00';
      _text(aCanvas, label, Offset(x, layout.plotHeight + _labelHeight / 2), aIsCentered: true);
    }

    for (final index in visible.reversed)
    {
      final person = people[index];
      final points = person.points;
      if (points.isEmpty)
      {
        continue;
      }
      final path = Path()..moveTo(layout.xOf(points.first.ts), layout.yOf(points.first.kcal));
      for (final point in points.skip(1))
      {
        path.lineTo(layout.xOf(point.ts), layout.yOf(point.kcal));
      }
      aCanvas.drawPath(
        path,
        Paint()
          ..color = colors[index]
          ..style = PaintingStyle.stroke
          ..strokeWidth = person.isMe ? _myLineWidth : _lineWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      final last = points.last;
      aCanvas.drawCircle(Offset(layout.xOf(last.ts), layout.yOf(last.kcal)), person.isMe ? 4 : 3, Paint()..color = colors[index]);
    }

    final shown = cursor;
    if (shown != null)
    {
      final x = layout.xOf(shown);
      aCanvas.drawLine(
        Offset(x, 0),
        Offset(x, layout.plotHeight),
        Paint()
          ..color = palette.inkMuted
          ..strokeWidth = 1,
      );
      for (final index in visible)
      {
        final value = energyAt(people[index].points, shown);
        if (value != null)
        {
          aCanvas.drawCircle(Offset(x, layout.yOf(value)), 4, Paint()..color = colors[index]);
        }
      }
    }
  }

  double _niceStep(double aRaw)
  {
    final magnitude = math.pow(10, (math.log(math.max(aRaw, 1)) / math.ln10).floor()).toDouble();
    for (final factor in [1.0, 2.0, 2.5, 5.0, 10.0])
    {
      if (factor * magnitude >= aRaw)
      {
        return factor * magnitude;
      }
    }
    return 10 * magnitude;
  }

  void _text(Canvas aCanvas, String aText, Offset aAnchor, {bool aAlignRight = false, bool aIsCentered = false})
  {
    final painter = TextPainter(
      text: TextSpan(text: aText, style: TextStyle(fontSize: 10, color: palette.inkMuted)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = aAlignRight ? aAnchor.dx - painter.width : (aIsCentered ? aAnchor.dx - painter.width / 2 : aAnchor.dx);
    painter.paint(aCanvas, Offset(dx, aAnchor.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _EnergyPainter aOld) =>
      aOld.layout.size != layout.size ||
      aOld.people != people ||
      aOld.cursor != cursor ||
      aOld.palette != palette ||
      aOld.visible.length != visible.length ||
      aOld.layout.low != layout.low ||
      aOld.layout.high != layout.high;
}
