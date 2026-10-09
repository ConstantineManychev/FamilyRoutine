import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../core/api_error.dart';

String errorText(Object aError)
{
  final key = ApiException.from(aError).messageKey;
  final text = key.tr();
  return text == key ? 'errors.UNKNOWN'.tr() : text;
}

void showErrorSnack(BuildContext aContext, Object aError)
{
  if (!aContext.mounted)
  {
    return;
  }

  ScaffoldMessenger.of(aContext).showSnackBar(
    SnackBar(content: Text(errorText(aError)), backgroundColor: Colors.red.shade800),
  );
}

void showInfoSnack(BuildContext aContext, String aMessage)
{
  if (!aContext.mounted)
  {
    return;
  }

  ScaffoldMessenger.of(aContext).showSnackBar(SnackBar(content: Text(aMessage)));
}

Future<bool> confirmAction(
  BuildContext aContext,
  {
    required String aTitle,
    required String aMessage,
    bool aIsDestructive = true,
  }
) async
{
  final isConfirmed = await showDialog<bool>(
    context: aContext,
    builder: (aDialogContext) => AlertDialog(
      title: Text(aTitle),
      content: Text(aMessage),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(aDialogContext).pop(false),
          child: Text('common.no'.tr()),
        ),
        ElevatedButton(
          style: aIsDestructive
              ? ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white)
              : null,
          onPressed: () => Navigator.of(aDialogContext).pop(true),
          child: Text('common.yes'.tr()),
        ),
      ],
    ),
  );

  return isConfirmed ?? false;
}

class ScreenHeader extends StatelessWidget
{
  final String title;
  final List<Widget> actions;

  const ScreenHeader({super.key, required this.title, this.actions = const []});

  @override
  Widget build(BuildContext aContext)
  {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        Text(title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }
}

class ErrorRetry extends StatelessWidget
{
  final Object error;
  final VoidCallback onRetry;

  const ErrorRetry({super.key, required this.error, required this.onRetry});

  @override
  Widget build(BuildContext aContext)
  {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(errorText(error), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: Text('common.retry'.tr())),
        ],
      ),
    );
  }
}

EdgeInsets screenPadding(BuildContext aContext)
{
  final isCompact = MediaQuery.sizeOf(aContext).width < 600;
  return EdgeInsets.all(isCompact ? 16 : 32);
}
