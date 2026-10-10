import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/api_prov.dart';
import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/money.dart';
import 'dash_card.dart';

class FamilyListCard extends ConsumerWidget
{
  final Widget? menu;

  const FamilyListCard({super.key, this.menu});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final famsAsync = aRef.watch(famsProv);

    return DashCard(
      title: Text('dashboard.active_fams'.tr()),
      actions: [
        TextButton(onPressed: () => aContext.go('/app/families'), child: Text('dashboard.all_fams'.tr())),
      ],
      menu: menu,
      child: famsAsync.when(
        loading: () => const LinearProgressIndicator(),
        error: (aError, _) => Text(errorText(aError)),
        data: (aFams) => aFams.isEmpty
            ? Text('dashboard.no_fams'.tr(), style: const TextStyle(color: inkMuted))
            : Column(
                children: aFams
                    .map((aFam) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(aFam.isOwner ? AppIcons.crown : AppIcons.users, color: inkSecondary),
                          title: Text(aFam.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('dashboard.members_count'.tr(args: ['${aFam.memberCount}'])),
                          trailing: const Icon(AppIcons.chevronRight, size: 18),
                          onTap: () => aContext.go('/app/families/${aFam.id}'),
                        ))
                    .toList(),
              ),
      ),
    );
  }
}
