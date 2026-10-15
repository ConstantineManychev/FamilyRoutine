import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import 'body_entry_editor.dart';
import 'metric_chart.dart';
import 'metric_format.dart';
import 'profile_screen.dart';
import '../common/app_theme.dart';

const double _contentMaxWidth = 960;

class MetricHistoryScreen extends ConsumerStatefulWidget
{
  final String personId;
  final BodyMetric metric;

  const MetricHistoryScreen({super.key, required this.personId, required this.metric});

  @override
  ConsumerState<MetricHistoryScreen> createState() => _MetricHistoryScreenState();
}

class _MetricHistoryScreenState extends ConsumerState<MetricHistoryScreen>
{
  PersonProfile? _profile;
  List<MetricPoint> _points = const [];
  Object? _loadError;
  bool _isBusy = false;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    setState(() => _loadError = null);
    try
    {
      final api = ref.read(apiProv);
      final profile = await api.getPerson(widget.personId);
      final points = await api.getMetricHistory(widget.personId, widget.metric);
      if (mounted)
      {
        setState(()
        {
          _profile = profile;
          _points = points;
        });
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        setState(() => _loadError = aError);
      }
    }
  }

  void _back()
  {
    final profile = _profile;
    if (context.canPop())
    {
      context.pop();
    }
    else
    {
      context.go(personPath(widget.personId, profile?.isSelf ?? false));
    }
  }

  Future<void> _edit(MetricPoint aPoint) async
  {
    final profile = _profile;
    if (profile == null)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      final entry = await ref.read(apiProv).getBodyEntry(widget.personId, aPoint.entryId);
      if (!mounted)
      {
        return;
      }
      final saved = await showBodyEntryEditor(
        context,
        aPersonId: widget.personId,
        aPersonName: profile.fullName,
        aLatest: profile.latest,
        aEntry: entry,
      );
      if (saved != null)
      {
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
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _delete(MetricPoint aPoint) async
  {
    final isConfirmed = await confirmAction(
      context,
      aTitle: 'metrics.delete_entry'.tr(),
      aMessage: 'metrics.delete_confirm'.tr(args: [formatMeasuredTs(context, aPoint.measuredTs)]),
    );
    if (!isConfirmed)
    {
      return;
    }
    setState(() => _isBusy = true);
    try
    {
      await ref.read(apiProv).deleteBodyEntry(widget.personId, aPoint.entryId);
      await _load();
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final profile = _profile;
    if (profile == null)
    {
      return _loadError != null
          ? ErrorRetry(error: _loadError!, onRetry: _load)
          : const Center(child: CircularProgressIndicator());
    }

    final points = _points;
    final trend = widget.metric == BodyMetric.weight && points.length > 2 ? trendOf(points) : null;

    return ListView(
      padding: screenPadding(aContext),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _contentMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(tooltip: 'common.back'.tr(), onPressed: _back, icon: const Icon(AppIcons.chevronLeft)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(metricName(widget.metric), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                          Text(profile.fullName, style: TextStyle(color: context.palette.inkSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (points.isEmpty)
                  Text('metrics.no_history'.tr(), style: TextStyle(color: context.palette.inkSecondary))
                else ...[
                  _buildSummary(aContext, points),
                  const SizedBox(height: 16),
                  MetricChart(metric: widget.metric, points: points, trend: trend),
                  if (trend != null) ...[
                    const SizedBox(height: 8),
                    Text('metrics.trend_hint'.tr(), style: TextStyle(color: context.palette.inkMuted, fontSize: 12)),
                  ],
                  const SizedBox(height: 24),
                  Text('metrics.history_list'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _buildList(aContext, profile, points),
                ],
                if (_isBusy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummary(BuildContext aContext, List<MetricPoint> aPoints)
  {
    final first = aPoints.first;
    final last = aPoints.last;
    final values = aPoints.map((aPoint) => aPoint.value);
    final low = values.reduce((aLeft, aRight) => aLeft < aRight ? aLeft : aRight);
    final high = values.reduce((aLeft, aRight) => aLeft > aRight ? aLeft : aRight);

    Widget stat(String aLabel, String aValue) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(aLabel, style: TextStyle(color: context.palette.inkSecondary, fontSize: 13)),
            Text(aValue, style: TextStyle(color: context.palette.inkPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
          ],
        );

    return Wrap(
      spacing: 32,
      runSpacing: 12,
      children: [
        stat('metrics.current'.tr(), formatMetric(aContext, widget.metric, last.value)),
        if (aPoints.length > 1)
          stat(
            'metrics.change_since'.tr(args: [formatMeasuredDate(aContext, first.measuredTs)]),
            formatMetric(aContext, widget.metric, last.value - first.value, aIsSigned: true),
          ),
        stat('metrics.min'.tr(), formatMetric(aContext, widget.metric, low)),
        stat('metrics.max'.tr(), formatMetric(aContext, widget.metric, high)),
      ],
    );
  }

  Widget _buildList(BuildContext aContext, PersonProfile aProfile, List<MetricPoint> aPoints)
  {
    final rows = <Widget>[];
    for (var index = aPoints.length - 1; index >= 0; index--)
    {
      final point = aPoints[index];
      final previous = index > 0 ? aPoints[index - 1] : null;
      final delta = previous == null ? null : point.value - previous.value;
      rows.add(ListTile(
        title: Text(formatMetric(aContext, widget.metric, point.value), style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text([
          formatMeasuredTs(aContext, point.measuredTs),
          if (delta != null) formatMetric(aContext, widget.metric, delta, aIsSigned: true),
        ].join(' · ')),
        trailing: aProfile.canEdit
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'metrics.edit_entry'.tr(),
                    onPressed: _isBusy ? null : () => _edit(point),
                    icon: const Icon(AppIcons.pencil, size: 18),
                  ),
                  IconButton(
                    tooltip: 'metrics.delete_entry'.tr(),
                    onPressed: _isBusy ? null : () => _delete(point),
                    icon: Icon(AppIcons.trash2, size: 18, color: context.palette.danger),
                  ),
                ],
              )
            : null,
      ));
      if (index > 0)
      {
        rows.add(const Divider(height: 1));
      }
    }

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.palette.border)),
      child: Column(children: rows),
    );
  }
}
