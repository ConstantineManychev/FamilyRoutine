import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../domain/models.dart';
import 'app_icons.dart';
import 'app_theme.dart';

const double _swipeVelocity = 250;
const double _dotSize = 7;
const Duration _switchDuration = Duration(milliseconds: 220);

String personLabel(PersonRef aPerson) => aPerson.isMe ? 'people.me'.tr() : aPerson.fullName;

Color personColor(BuildContext aContext, int aIndex)
{
  final series = aContext.palette.series;
  return series[aIndex % series.length];
}

String? personQuery(PersonRef? aPerson) => aPerson == null || aPerson.isMe ? null : aPerson.id;

class PersonSwipe extends StatelessWidget
{
  final List<PersonRef> people;
  final int index;
  final ValueChanged<int> onChanged;
  final Widget child;

  const PersonSwipe({
    super.key,
    required this.people,
    required this.index,
    required this.onChanged,
    required this.child,
  });

  void _step(int aDelta)
  {
    final next = index + aDelta;
    if (next >= 0 && next < people.length)
    {
      onChanged(next);
    }
  }

  void _onDragEnd(DragEndDetails aDetails)
  {
    final velocity = aDetails.primaryVelocity ?? 0;
    if (velocity <= -_swipeVelocity)
    {
      _step(1);
    }
    else if (velocity >= _swipeVelocity)
    {
      _step(-1);
    }
  }

  @override
  Widget build(BuildContext aContext)
  {
    if (people.length < 2)
    {
      return child;
    }
    final person = people[index];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PersonStrip(people: people, index: index, onChanged: onChanged),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: _onDragEnd,
          child: AnimatedSwitcher(
            duration: _switchDuration,
            child: KeyedSubtree(key: ValueKey(person.id), child: child),
          ),
        ),
      ],
    );
  }
}

class PersonStrip extends StatelessWidget
{
  final List<PersonRef> people;
  final int index;
  final ValueChanged<int> onChanged;

  const PersonStrip({super.key, required this.people, required this.index, required this.onChanged});

  @override
  Widget build(BuildContext aContext)
  {
    final palette = aContext.palette;
    final person = people[index];

    return Row(
      children: [
        IconButton(
          key: const ValueKey('person.prev'),
          tooltip: 'people.prev'.tr(),
          visualDensity: VisualDensity.compact,
          onPressed: index > 0 ? () => onChanged(index - 1) : null,
          icon: const Icon(AppIcons.chevronLeft, size: 18),
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      personLabel(person),
                      key: const ValueKey('person.name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkPrimary),
                    ),
                  ),
                  if (person.isManaged) ...[
                    const SizedBox(width: 6),
                    Text('people.child'.tr(), style: TextStyle(fontSize: 12, color: palette.inkSecondary)),
                  ],
                  if (!person.canEdit) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'people.view_only'.tr(),
                      child: Icon(AppIcons.eye, size: 14, color: palette.inkMuted),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var dot = 0; dot < people.length; dot++)
                    GestureDetector(
                      onTap: () => onChanged(dot),
                      child: AnimatedContainer(
                        duration: _switchDuration,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: dot == index ? _dotSize * 2 : _dotSize,
                        height: _dotSize,
                        decoration: BoxDecoration(
                          color: dot == index ? personColor(aContext, dot) : palette.border,
                          borderRadius: BorderRadius.circular(_dotSize),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('person.next'),
          tooltip: 'people.next'.tr(),
          visualDensity: VisualDensity.compact,
          onPressed: index < people.length - 1 ? () => onChanged(index + 1) : null,
          icon: const Icon(AppIcons.chevronRight, size: 18),
        ),
      ],
    );
  }
}
