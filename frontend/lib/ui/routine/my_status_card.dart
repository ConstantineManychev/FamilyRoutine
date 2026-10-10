import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'dash_card.dart';
import 'routine_style.dart';

const List<int> _offsetMinutes = [0, 15, 30, 60];

class MyStatusCard extends ConsumerStatefulWidget
{
  final Widget? menu;

  const MyStatusCard({super.key, this.menu});

  @override
  ConsumerState<MyStatusCard> createState() => _MyStatusCardState();
}

class _MyStatusCardState extends ConsumerState<MyStatusCard>
{
  final _noteCtrl = TextEditingController();

  StatusMarkDto? _current;
  int _offset = 0;
  TimeOfDay? _customTime;
  bool _isSaving = false;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  @override
  void dispose()
  {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async
  {
    final now = DateTime.now();
    try
    {
      final timeline = await ref.read(apiProv).getTimeline(
            aFrom: now.subtract(const Duration(days: 2)),
            aTo: now.add(const Duration(minutes: 1)),
          );
      final me = timeline.members.firstOrNull;
      if (mounted)
      {
        setState(()
        {
          _current = me?.markAt(now);
          _error = null;
        });
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

  DateTime _startTs()
  {
    final now = DateTime.now();
    final custom = _customTime;
    if (custom == null)
    {
      return now.subtract(Duration(minutes: _offset));
    }
    final today = DateTime(now.year, now.month, now.day, custom.hour, custom.minute);
    return today.isAfter(now) ? today.subtract(const Duration(days: 1)) : today;
  }

  Future<void> _pickTime() async
  {
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (picked != null)
    {
      setState(() => _customTime = picked);
    }
  }

  Future<void> _setStatus(RoutineStatus aStatus) async
  {
    setState(() => _isSaving = true);
    try
    {
      await ref.read(apiProv).createMark(aStatus, aNote: _noteCtrl.text, aStartTs: _offset == 0 && _customTime == null ? null : _startTs());
      if (!mounted)
      {
        return;
      }
      _noteCtrl.clear();
      setState(()
      {
        _offset = 0;
        _customTime = null;
      });
      ref.read(routineRevisionProv.notifier).state++;
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
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    ref.listen<int>(routineRevisionProv, (_, __) => _load());
    final current = _current;

    return DashCard(
      title: Text('routine.my_status'.tr()),
      actions: [
        if (current != null)
          StatusBadge(
            status: current.status,
            caption: '${'routine.since'.tr(args: [formatClock(aContext, current.startTs)])}'
                '${current.note == null ? '' : ' · ${current.note}'}',
          ),
      ],
      menu: widget.menu,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(errorText(_error!), style: TextStyle(color: Colors.red.shade800)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: RoutineStatus.values.map((aStatus) => _StatusButton(
                  status: aStatus,
                  isActive: current?.status == aStatus,
                  onPressed: _isSaving ? null : () => _setStatus(aStatus),
                )).toList(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('routine.started'.tr(), style: const TextStyle(color: inkSecondary)),
              ..._offsetMinutes.map((aMinutes) => ChoiceChip(
                    showCheckmark: false,
                    label: Text(aMinutes == 0 ? 'routine.now'.tr() : 'routine.ago'.tr(args: [formatDuration(Duration(minutes: aMinutes))])),
                    selected: _customTime == null && _offset == aMinutes,
                    onSelected: (_) => setState(()
                    {
                      _offset = aMinutes;
                      _customTime = null;
                    }),
                  )),
              ChoiceChip(
                showCheckmark: false,
                avatar: const Icon(AppIcons.clock, size: 16),
                label: Text(_customTime == null ? 'routine.pick_time'.tr() : _customTime!.format(aContext)),
                selected: _customTime != null,
                onSelected: (_) => _pickTime(),
              ),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _noteCtrl,
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  decoration: InputDecoration(
                    labelText: 'routine.note'.tr(),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusButton extends StatelessWidget
{
  final RoutineStatus status;
  final bool isActive;
  final VoidCallback? onPressed;

  const _StatusButton({required this.status, required this.isActive, required this.onPressed});

  @override
  Widget build(BuildContext aContext)
  {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: inkPrimary,
        backgroundColor: isActive ? status.color.withValues(alpha: 0.14) : null,
        side: BorderSide(color: isActive ? status.color : const Color(0xFFE5E7EB), width: isActive ? 2 : 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      icon: Icon(status.icon, size: 18, color: status.color),
      label: Text(status.label),
    );
  }
}
