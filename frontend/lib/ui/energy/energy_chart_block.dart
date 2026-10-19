import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import '../common/person_switcher.dart';
import '../common/range_days.dart';
import '../nutrition/nutrition_format.dart' show formatAmount, formatKcal, nutritionRevisionProv;
import '../planner/planner_common.dart';
import '../routine/routine_style.dart';
import '../training/training_revision.dart';

const double _chartHeight = 220;
const double _axisWidth = 48;
const double _labelHeight = 32;
const double _tooltipWidth = 200;
const double _lineWidth = 2;
const double _myLineWidth = 3;
const double _minSpan = 500;
const double _minDayWidth = 96;
const double _minTickGap = 44;
const double _markSize = 5;
const int _markMatchMinutes = 30;
const int _maxCorrection = 100000;
const List<int> _hourSteps = [1, 2, 3, 6, 12, 24];
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

double? energyNear(List<EnergyPoint> aPoints, DateTime aMoment)
{
  if (aPoints.isEmpty)
  {
    return null;
  }
  if (aMoment.isBefore(aPoints.first.ts))
  {
    return aPoints.first.kcal;
  }
  return energyAt(aPoints, aMoment.isAfter(aPoints.last.ts) ? aPoints.last.ts : aMoment);
}

String formatSignedKcal(BuildContext aContext, num aValue)
{
  final text = formatKcal(aContext, aValue.abs().toDouble());
  return aValue > 0 ? '+$text' : (aValue < 0 ? '−$text' : text);
}

EnergyMark? markNear(EnergyPerson aPerson, DateTime aTs) => aPerson.marks
    .where((aMark) => aMark.ts.difference(aTs).inMinutes.abs() <= _markMatchMinutes)
    .firstOrNull;

class EnergyChartBlock extends ConsumerStatefulWidget
{
  const EnergyChartBlock({super.key});

  @override
  ConsumerState<EnergyChartBlock> createState() => _EnergyChartBlockState();
}

class _EnergyChartBlockState extends ConsumerState<EnergyChartBlock>
{
  DateTime _lastDay = dayOnly(DateTime.now());
  int _days = 1;
  EnergyDay? _day;
  Object? _error;
  Timer? _timer;
  int _request = 0;
  final Set<String> _hidden = {};

  bool get _isCurrent => _lastDay == dayOnly(DateTime.now());

  @override
  void initState()
  {
    super.initState();
    _load();
    _timer = Timer.periodic(_refreshInterval, (_)
    {
      if (mounted && _isCurrent)
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
      final day = await ref.read(apiProv).getEnergyDay(_lastDay, aDays: _days);
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

  void _setRange(DateTime aLastDay, int aDays)
  {
    setState(()
    {
      _lastDay = dayOnly(aLastDay);
      _days = aDays;
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

  Future<void> _correct(EnergyDay aDay, DateTime aTs, String? aNearestId) async
  {
    final editable = aDay.people.where((aPerson) => aPerson.canEdit).toList();
    if (editable.isEmpty)
    {
      return;
    }
    final now = DateTime.now();
    final ts = aTs.isAfter(now) ? now : aTs;
    final initial = editable.where((aPerson) => aPerson.personId == aNearestId).firstOrNull ?? editable.first;
    final choice = await showDialog<_Correction>(
      context: context,
      builder: (_) => _CorrectionDialog(people: editable, initial: initial, ts: ts),
    );
    if (choice == null || !mounted)
    {
      return;
    }
    final api = ref.read(apiProv);
    try
    {
      final deleteId = choice.deleteMarkId;
      if (deleteId != null)
      {
        await api.deleteEnergyMark(deleteId);
      }
      else
      {
        await api.setEnergyMark(
          aPersonId: choice.person.isMe ? null : choice.person.personId,
          aTs: ts,
          aKcal: choice.kcal,
        );
      }
      if (mounted)
      {
        showInfoSnack(context, deleteId != null ? 'energy.mark_deleted'.tr() : 'energy.mark_saved'.tr());
        await _load();
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
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
            EnergyChart(
              key: ValueKey('energy.chart.${day.dayStart.toIso8601String()}.${day.days}'),
              day: day,
              hidden: _hidden,
              onPick: (aTs, aNearestId) => _correct(day, aTs, aNearestId),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < day.people.length; index++)
                  _LegendChip(
                    person: day.people[index],
                    days: day.days,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: RangeDaysBar(
              keyPrefix: 'energy.range',
              lastDay: _lastDay,
              days: _days,
              onShift: (aDay) => _setRange(aDay, _days),
              onDays: (aDays) => _setRange(_lastDay, aDays),
            ),
          ),
          content,
        ],
      ),
    );
  }
}

class _Correction
{
  final EnergyPerson person;
  final double kcal;
  final String? deleteMarkId;

  const _Correction(this.person, this.kcal, {this.deleteMarkId});
}

class _CorrectionDialog extends StatefulWidget
{
  final List<EnergyPerson> people;
  final EnergyPerson initial;
  final DateTime ts;

  const _CorrectionDialog({required this.people, required this.initial, required this.ts});

  @override
  State<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<_CorrectionDialog>
{
  late EnergyPerson _person = widget.initial;
  late final _ctrl = TextEditingController(text: _valueText(widget.initial));

  String _valueText(EnergyPerson aPerson) => (energyNear(aPerson.points, widget.ts) ?? 0).round().toString();

  @override
  void dispose()
  {
    _ctrl.dispose();
    super.dispose();
  }

  int? get _kcal
  {
    final text = _ctrl.text.trim().replaceAll('−', '-').replaceAll(' ', '');
    final value = int.tryParse(text);
    return value == null || value.abs() > _maxCorrection ? null : value;
  }

  void _select(EnergyPerson aPerson)
  {
    setState(()
    {
      _person = aPerson;
      _ctrl.text = _valueText(aPerson);
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final locale = aContext.locale.toLanguageTag();
    final kcal = _kcal;
    final mark = markNear(_person, widget.ts);
    final when = '${DateFormat.MMMEd(locale).format(widget.ts)}, ${formatClock(aContext, widget.ts)}';

    return AlertDialog(
      scrollable: true,
      title: Text('energy.correct_title'.tr()),
      content: SizedBox(
        width: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(when, key: const ValueKey('energy.correct.when'), style: TextStyle(color: palette.inkSecondary)),
            if (widget.people.length > 1) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final person in widget.people)
                    ChoiceChip(
                      key: ValueKey('energy.correct.person.${person.personId}'),
                      showCheckmark: false,
                      label: Text(person.isMe ? 'people.me'.tr() : person.fullName),
                      selected: person.personId == _person.personId,
                      onSelected: (_) => _select(person),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('energy.correct.kcal'),
              controller: _ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-−0-9 ]')), LengthLimitingTextInputFormatter(8)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'energy.correct_kcal'.tr(),
                suffixText: 'energy.kcal_unit'.tr(),
                helperText: 'energy.correct_hint'.tr(),
                helperMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (mark != null)
          TextButton(
            key: const ValueKey('energy.correct.delete'),
            style: TextButton.styleFrom(foregroundColor: palette.danger),
            onPressed: () => Navigator.of(aContext).pop(_Correction(_person, 0, deleteMarkId: mark.id)),
            child: Text('energy.mark_delete'.tr()),
          ),
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          key: const ValueKey('energy.correct.save'),
          onPressed: kcal == null ? null : () => Navigator.of(aContext).pop(_Correction(_person, kcal.toDouble())),
          child: Text('common.ok'.tr()),
        ),
      ],
    );
  }
}

class _LegendChip extends StatelessWidget
{
  final EnergyPerson person;
  final int days;
  final Color color;
  final bool isHidden;
  final VoidCallback onTap;

  const _LegendChip({required this.person, required this.days, required this.color, required this.isHidden, required this.onTap});

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
                      Text(
                        days > 1 ? '${'energy.period'.plural(days)}: $details' : details,
                        style: TextStyle(fontSize: 11, color: palette.inkSecondary),
                      ),
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
  final void Function(DateTime aTs, String? aNearestId)? onPick;

  const EnergyChart({super.key, required this.day, this.hidden = const {}, this.onPick});

  @override
  State<EnergyChart> createState() => _EnergyChartState();
}

class _EnergyChartState extends State<EnergyChart>
{
  final _scroll = ScrollController();
  DateTime? _cursor;
  bool _isScrolledToEnd = false;

  @override
  void dispose()
  {
    _scroll.dispose();
    super.dispose();
  }

  List<int> get _visible => [
        for (var index = 0; index < widget.day.people.length; index++)
          if (!widget.hidden.contains(widget.day.people[index].personId) && widget.day.people[index].points.isNotEmpty) index,
      ];

  void _hover(Offset aPosition, _EnergyLayout aLayout)
  {
    setState(() => _cursor = aLayout.tsOf(aPosition.dx));
  }

  void _pick(Offset aPosition, _EnergyLayout aLayout)
  {
    final ts = aLayout.tsOf(aPosition.dx);
    String? nearest;
    var bestDistance = double.infinity;
    for (final index in _visible)
    {
      final person = widget.day.people[index];
      final value = energyNear(person.points, ts);
      if (value == null)
      {
        continue;
      }
      final distance = (aLayout.yOf(value) - aPosition.dy).abs();
      if (distance < bestDistance)
      {
        bestDistance = distance;
        nearest = person.personId;
      }
    }
    setState(() => _cursor = ts);
    widget.onPick?.call(ts, nearest);
  }

  void _scrollToEnd()
  {
    if (_isScrolledToEnd)
    {
      return;
    }
    _isScrolledToEnd = true;
    WidgetsBinding.instance.addPostFrameCallback((_)
    {
      if (mounted && _scroll.hasClients)
      {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext aContext)
  {
    return LayoutBuilder(
      builder: (_, aConstraints)
      {
        final viewport = math.max(120.0, aConstraints.maxWidth - _axisWidth);
        final width = rangeContentWidth(viewport, widget.day.days, _minDayWidth);
        final visible = _visible;
        final layout = _EnergyLayout(widget.day, visible, Size(width, _chartHeight + _labelHeight));
        final colors = [for (var index = 0; index < widget.day.people.length; index++) personColor(aContext, index)];
        final cursor = _cursor;
        if (width > viewport)
        {
          _scrollToEnd();
        }

        return SizedBox(
          height: _chartHeight + _labelHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: _axisWidth,
                height: _chartHeight + _labelHeight,
                child: CustomPaint(
                  painter: _AxisPainter(
                    layout: layout,
                    palette: aContext.palette,
                    valueLabel: (aValue) => formatAmount(aContext, aValue, aDigits: 0),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('energy.scroll'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  child: MouseRegion(
                    onHover: (aEvent) => _hover(aEvent.localPosition, layout),
                    onExit: (_) => setState(() => _cursor = null),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (aDetails) => _pick(aDetails.localPosition, layout),
                      child: SizedBox(
                        width: width,
                        height: _chartHeight + _labelHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: CustomPaint(
                                key: const ValueKey('energy.chart'),
                                painter: _PlotPainter(
                                  layout: layout,
                                  people: widget.day.people,
                                  visible: visible,
                                  colors: colors,
                                  palette: aContext.palette,
                                  cursor: cursor,
                                  hourLabel: (aTs) => formatClock(aContext, aTs),
                                  dayLabel: (aTs) => DateFormat.MMMd(aContext.locale.toLanguageTag()).format(aTs),
                                ),
                              ),
                            ),
                            if (cursor != null) _buildTooltip(aContext, layout, visible, colors, cursor),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
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
    final local = aCursor.toLocal();

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
                Text(
                  widget.day.days > 1
                      ? '${DateFormat.MMMd(aContext.locale.toLanguageTag()).format(local)}, ${formatClock(aContext, local)}'
                      : formatClock(aContext, local),
                  style: TextStyle(fontSize: 12, color: aContext.palette.inkSecondary),
                ),
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

  double get plotLeft => 4;

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

  double get valueStep
  {
    final raw = (high - low) / 4;
    final magnitude = math.pow(10, (math.log(math.max(raw, 1)) / math.ln10).floor()).toDouble();
    for (final factor in [1.0, 2.0, 2.5, 5.0, 10.0])
    {
      if (factor * magnitude >= raw)
      {
        return factor * magnitude;
      }
    }
    return 10 * magnitude;
  }

  Iterable<double> get valueTicks sync*
  {
    final step = valueStep;
    for (var value = (low / step).ceil() * step; value <= high; value += step)
    {
      yield value;
    }
  }

  int get hourStep
  {
    final hours = math.max(1, end.difference(start).inMinutes / 60);
    final perHour = (plotRight - plotLeft) / hours;
    return _hourSteps.firstWhere((aStep) => aStep * perHour >= _minTickGap, orElse: () => 24);
  }
}

void _paintText(Canvas aCanvas, String aText, Offset aAnchor, Color aColor, {bool aAlignRight = false, bool aIsCentered = false, bool aIsBold = false})
{
  final painter = TextPainter(
    text: TextSpan(text: aText, style: TextStyle(fontSize: 10, color: aColor, fontWeight: aIsBold ? FontWeight.w700 : FontWeight.w400)),
    textDirection: TextDirection.ltr,
  )..layout();
  final dx = aAlignRight ? aAnchor.dx - painter.width : (aIsCentered ? aAnchor.dx - painter.width / 2 : aAnchor.dx);
  painter.paint(aCanvas, Offset(dx, aAnchor.dy - painter.height / 2));
}

class _AxisPainter extends CustomPainter
{
  final _EnergyLayout layout;
  final AppPalette palette;
  final String Function(double) valueLabel;

  _AxisPainter({required this.layout, required this.palette, required this.valueLabel});

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    for (final value in layout.valueTicks)
    {
      _paintText(aCanvas, valueLabel(value), Offset(aSize.width - 6, layout.yOf(value)), palette.inkMuted, aAlignRight: true);
    }
  }

  @override
  bool shouldRepaint(covariant _AxisPainter aOld) =>
      aOld.layout.low != layout.low || aOld.layout.high != layout.high || aOld.palette != palette;
}

class _PlotPainter extends CustomPainter
{
  final _EnergyLayout layout;
  final List<EnergyPerson> people;
  final List<int> visible;
  final List<Color> colors;
  final AppPalette palette;
  final DateTime? cursor;
  final String Function(DateTime) hourLabel;
  final String Function(DateTime) dayLabel;

  _PlotPainter({
    required this.layout,
    required this.people,
    required this.visible,
    required this.colors,
    required this.palette,
    required this.cursor,
    required this.hourLabel,
    required this.dayLabel,
  });

  @override
  void paint(Canvas aCanvas, Size aSize)
  {
    final grid = Paint()
      ..color = palette.grid
      ..strokeWidth = 1;
    final strong = Paint()
      ..color = palette.baseline
      ..strokeWidth = 1.5;
    for (final value in layout.valueTicks)
    {
      final y = layout.yOf(value);
      aCanvas.drawLine(Offset(layout.plotLeft, y), Offset(layout.plotRight, y), value.abs() < 1e-6 ? strong : grid);
    }

    final step = layout.hourStep;
    final localStart = layout.start.toLocal();
    var tick = DateTime(localStart.year, localStart.month, localStart.day, localStart.hour);
    final localEnd = layout.end.toLocal();
    final isMultiDay = layout.end.difference(layout.start).inHours > 26;
    while (!tick.isAfter(localEnd))
    {
      final isMidnight = tick.hour == 0;
      if (tick.hour % step == 0 || isMidnight)
      {
        final x = layout.xOf(tick.toUtc());
        aCanvas.drawLine(Offset(x, 0), Offset(x, layout.plotHeight), isMidnight && isMultiDay ? strong : grid);
        final labelY = layout.plotHeight + 9;
        if (isMidnight && isMultiDay)
        {
          _paintText(aCanvas, dayLabel(tick), Offset(x, labelY + 12), palette.inkSecondary, aIsCentered: true, aIsBold: true);
        }
        if (step < 24)
        {
          _paintText(aCanvas, hourLabel(tick), Offset(x, labelY), palette.inkMuted, aIsCentered: true);
        }
      }
      tick = DateTime(tick.year, tick.month, tick.day, tick.hour + 1);
    }

    for (final index in visible.reversed)
    {
      final person = people[index];
      final points = person.points;
      if (points.isEmpty)
      {
        continue;
      }
      final color = colors[index];
      final path = Path()..moveTo(layout.xOf(points.first.ts), layout.yOf(points.first.kcal));
      for (final point in points.skip(1))
      {
        path.lineTo(layout.xOf(point.ts), layout.yOf(point.kcal));
      }
      aCanvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = person.isMe ? _myLineWidth : _lineWidth
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
      final last = points.last;
      aCanvas.drawCircle(Offset(layout.xOf(last.ts), layout.yOf(last.kcal)), person.isMe ? 4 : 3, Paint()..color = color);
      for (final mark in person.marks)
      {
        final center = Offset(layout.xOf(mark.ts), layout.yOf(mark.kcal));
        final diamond = Path()
          ..moveTo(center.dx, center.dy - _markSize)
          ..lineTo(center.dx + _markSize, center.dy)
          ..lineTo(center.dx, center.dy + _markSize)
          ..lineTo(center.dx - _markSize, center.dy)
          ..close();
        aCanvas.drawPath(diamond, Paint()..color = palette.surface);
        aCanvas.drawPath(
          diamond,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
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

  @override
  bool shouldRepaint(covariant _PlotPainter aOld) => true;
}
