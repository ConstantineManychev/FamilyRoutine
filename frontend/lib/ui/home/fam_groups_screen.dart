import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import 'fam_groups_grid.dart';

class FamGroupsScreen extends ConsumerWidget
{
  const FamGroupsScreen({super.key});

  Future<void> _handleDelete(BuildContext aContext, WidgetRef aRef, String aFamId) async
  {
    try
    {
      await aRef.read(apiProv).deleteFam(aFamId);
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
    }
    aRef.invalidate(famsProv);
  }

  Future<void> _handleLeave(BuildContext aContext, WidgetRef aRef, String aFamId) async
  {
    try
    {
      await aRef.read(apiProv).leaveFam(aFamId);
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
    }
    aRef.invalidate(famsProv);
  }

  Future<void> _joinByCode(BuildContext aContext, WidgetRef aRef) async
  {
    final code = await showDialog<String>(context: aContext, builder: (_) => const _JoinCodeDialog());

    if (code == null || code.trim().isEmpty || !aContext.mounted)
    {
      return;
    }

    try
    {
      final famId = await aRef.read(apiProv).acceptInvite(code.trim());
      aRef.invalidate(famsProv);
      if (aContext.mounted)
      {
        showInfoSnack(aContext, 'family.joined'.tr());
        aContext.go('/app/families/$famId');
      }
    }
    catch (aError)
    {
      if (aContext.mounted)
      {
        showErrorSnack(aContext, aError);
      }
    }
  }

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final famsAsync = aRef.watch(famsProv);

    return Padding(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ScreenHeader(
            title: 'sidebar.family_groups'.tr(),
            actions: [
              OutlinedButton.icon(
                onPressed: () => _joinByCode(aContext, aRef),
                icon: const Icon(AppIcons.keyRound, size: 18),
                label: Text('family.join_by_code'.tr()),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Expanded(
            child: famsAsync.when(
              data: (aFams) => FamGroupsGrid(
                fams: aFams,
                onCreateFam: () => aContext.go('/app/families/new'),
                onSelectFam: (aId) => aContext.go('/app/families/$aId'),
                onDeleteFam: (aId) => _handleDelete(aContext, aRef, aId),
                onLeaveFam: (aId) => _handleLeave(aContext, aRef, aId),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (aError, _) => ErrorRetry(error: aError, onRetry: () => aRef.invalidate(famsProv)),
            ),
          ),
        ],
      ),
    );
  }
}

class _JoinCodeDialog extends StatefulWidget
{
  const _JoinCodeDialog();

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog>
{
  final _codeCtrl = TextEditingController();

  @override
  void dispose()
  {
    _codeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext aContext)
  {
    return AlertDialog(
      title: Text('family.join_by_code'.tr()),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('family.join_hint'.tr()),
          const SizedBox(height: 16),
          TextField(
            controller: _codeCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(20)],
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'XXXX-XXXX-XXXX'),
            onSubmitted: (aValue) => Navigator.of(aContext).pop(aValue),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(aContext).pop(), child: Text('common.cancel'.tr())),
        ElevatedButton(
          onPressed: () => Navigator.of(aContext).pop(_codeCtrl.text),
          child: Text('family.join'.tr()),
        ),
      ],
    );
  }
}
