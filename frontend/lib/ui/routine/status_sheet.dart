import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'routine_style.dart';

const List<int> _offsetMinutes = [0, 15, 30, 60];
const double _badgeSize = 18;
const int _maxNoteLen = 200;

final FutureProvider<StatusMarkDto?> currentMarkProv = FutureProvider<StatusMarkDto?>((aRef)
{
  aRef.watch(routineRevisionProv);
  if (aRef.watch(sessionUserIdProv) == null)
  {
    return Future.value();
  }
  return aRef.read(apiProv).getCurrentMark();
});

String statusCaption(BuildContext aContext, StatusMarkDto? aMark)
{
  if (aMark == null)
  {
    return 'routine.set_status'.tr();
  }
  return '${aMark.status.label} · ${'routine.since'.tr(args: [formatClock(aContext, aMark.startTs)])}';
}

class StatusAvatar extends ConsumerWidget
{
  final String initials;
  final double radius;

  const StatusAvatar({super.key, required this.initials, this.radius = 20});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    final current = aRef.watch(currentMarkProv).valueOrNull;
    final palette = aContext.palette;

    return SizedBox(
      width: radius * 2 + 4,
      height: radius * 2 + 4,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: radius,
            backgroundColor: aContext.colors.primary,
            foregroundColor: aContext.colors.onPrimary,
            child: Text(initials.isEmpty ? '?' : initials, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (current != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Semantics(
                label: current.status.label,
                child: Container(
                  key: const ValueKey('status.badge'),
                  width: _badgeSize,
                  height: _badgeSize,
                  decoration: BoxDecoration(
                    color: current.status.colorOf(aContext),
                    shape: BoxShape.circle,
                    border: Border.all(color: palette.surface, width: 2),
                  ),
                  child: Icon(current.status.icon, size: 10, color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class StatusLine extends ConsumerWidget
{
  const StatusLine({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final current = aRef.watch(currentMarkProv).valueOrNull;
    final palette = aContext.palette;
    final caption = statusCaption(aContext, current);

    return Semantics(
      button: true,
      label: 'routine.change_status'.tr(args: [caption]),
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('status.line'),
        borderRadius: BorderRadius.circular(6),
        onTap: () => showStatusSheet(aContext),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: current == null ? palette.inkMuted : current.status.colorOf(aContext),
                  ),
                ),
              ),
              Icon(AppIcons.chevronDown, size: 14, color: palette.inkSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showStatusSheet(BuildContext aContext)
{
  return showModalBottomSheet<void>(
    context: aContext,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const StatusSheet(),
  );
}

class StatusSheet extends ConsumerStatefulWidget
{
  const StatusSheet({super.key});

  @override
  ConsumerState<StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends ConsumerState<StatusSheet>
{
  final _noteCtrl = TextEditingController();
  int _offset = 0;
  TimeOfDay? _customTime;
  bool _isSaving = false;

  @override
  void dispose()
  {
    _noteCtrl.dispose();
    super.dispose();
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
    if (picked != null && mounted)
    {
      setState(() => _customTime = picked);
    }
  }

  Future<void> _setStatus(RoutineStatus aStatus) async
  {
    setState(() => _isSaving = true);
    try
    {
      final isNow = _offset == 0 && _customTime == null;
      await ref.read(apiProv).createMark(aStatus, aNote: _noteCtrl.text, aStartTs: isNow ? null : _startTs());
      ref.read(routineRevisionProv.notifier).state++;
      if (mounted)
      {
        Navigator.of(context).pop();
      }
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final media = MediaQuery.of(aContext);
    final palette = aContext.palette;
    final current = ref.watch(currentMarkProv).valueOrNull;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: (media.size.height - media.viewInsets.bottom) * 0.9),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + media.padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('routine.my_status'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                current == null
                    ? 'routine.no_status'.tr()
                    : '${'routine.now_label'.tr()}: ${statusCaption(aContext, current)}${current.note == null ? '' : ' · ${current.note}'}',
                style: TextStyle(color: palette.inkSecondary),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final status in RoutineStatus.values)
                    OutlinedButton.icon(
                      key: ValueKey('status.pick.${status.name}'),
                      onPressed: _isSaving ? null : () => _setStatus(status),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: palette.inkPrimary,
                        backgroundColor: current?.status == status ? status.colorOf(aContext).withValues(alpha: 0.14) : null,
                        side: BorderSide(
                          color: current?.status == status ? status.colorOf(aContext) : palette.border,
                          width: current?.status == status ? 2 : 1,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      icon: Icon(status.icon, size: 18, color: status.colorOf(aContext)),
                      label: Text(status.label),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('routine.start_earlier'.tr(), style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkSecondary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final minutes in _offsetMinutes)
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text(minutes == 0 ? 'routine.now'.tr() : 'routine.ago'.tr(args: [formatDuration(Duration(minutes: minutes))])),
                      selected: _customTime == null && _offset == minutes,
                      onSelected: (_) => setState(()
                      {
                        _offset = minutes;
                        _customTime = null;
                      }),
                    ),
                  ChoiceChip(
                    showCheckmark: false,
                    avatar: const Icon(AppIcons.clock, size: 16),
                    label: Text(_customTime == null ? 'routine.pick_time'.tr() : _customTime!.format(aContext)),
                    selected: _customTime != null,
                    onSelected: (_) => _pickTime(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _noteCtrl,
                inputFormatters: [LengthLimitingTextInputFormatter(_maxNoteLen)],
                decoration: InputDecoration(labelText: 'routine.note'.tr(), border: const OutlineInputBorder(), isDense: true),
              ),
              const SizedBox(height: 8),
              Text('routine.pick_hint'.tr(), style: TextStyle(fontSize: 12, color: palette.inkMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
