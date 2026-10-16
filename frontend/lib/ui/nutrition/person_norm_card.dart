import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/app_theme.dart';
import '../common/feedback.dart';
import 'goal_screen.dart';
import 'nutrition_diary_screen.dart';
import 'nutrition_format.dart';

class PersonNormCard extends ConsumerStatefulWidget
{
  final String personId;
  final bool isSelf;

  const PersonNormCard({super.key, required this.personId, this.isSelf = false});

  @override
  ConsumerState<PersonNormCard> createState() => _PersonNormCardState();
}

class _PersonNormCardState extends ConsumerState<PersonNormCard>
{
  PersonNorm? _norm;
  Object? _error;

  @override
  void initState()
  {
    super.initState();
    _load();
  }

  Future<void> _load() async
  {
    try
    {
      final norm = await ref.read(apiProv).getPersonNorm(widget.personId, dayOnly(DateTime.now()));
      if (mounted)
      {
        setState(()
        {
          _norm = norm;
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

  Future<void> _openGoal() async
  {
    await context.push(goalPath);
    await _load();
  }

  @override
  Widget build(BuildContext aContext)
  {
    ref.listen<int>(nutritionRevisionProv, (_, __) => _load());
    final palette = aContext.palette;
    final data = _norm;
    final Widget content;
    if (_error != null)
    {
      content = ErrorRetry(error: _error!, onRetry: _load);
    }
    else if (data == null)
    {
      content = const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    }
    else
    {
      final norm = data.norm;
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (norm != null) NormDetails(norm: norm) else Text(normGapText(data.normGaps), style: TextStyle(color: palette.inkSecondary)),
          const SizedBox(height: 10),
          Text(
            norm == null
                ? 'goal.eaten_today'.tr(args: [formatAmount(aContext, data.eaten.kcal, aDigits: 0)])
                : 'goal.eaten_of'.tr(args: [
                    formatAmount(aContext, data.eaten.kcal, aDigits: 0),
                    formatAmount(aContext, norm.target.kcal, aDigits: 0),
                  ]),
            key: const ValueKey('person.norm.eaten'),
            style: TextStyle(fontWeight: FontWeight.w600, color: palette.inkPrimary),
          ),
        ],
      );
    }

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      semanticContainer: false,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: palette.border)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(AppIcons.utensils, size: 20, color: palette.inkSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('goal.card_title'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                if (widget.isSelf)
                  TextButton.icon(
                    key: const ValueKey('person.norm.goal'),
                    onPressed: _openGoal,
                    icon: const Icon(AppIcons.slidersHorizontal, size: 16),
                    label: Text('goal.title'.tr()),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            content,
          ],
        ),
      ),
    );
  }
}
