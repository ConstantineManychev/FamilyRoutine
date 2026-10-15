import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../common/app_icons.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'groups_tab.dart';

class FamGroupsScreen extends ConsumerStatefulWidget
{
  const FamGroupsScreen({super.key});

  @override
  ConsumerState<FamGroupsScreen> createState() => _FamGroupsScreenState();
}

class _FamGroupsScreenState extends ConsumerState<FamGroupsScreen>
{
  String _query = '';

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;
    final actions = GroupsActions(aContext, ref);

    return ListPage(
      title: 'sidebar.family_groups'.tr(),
      onAdd: actions.create,
      addTooltip: 'family.create_group'.tr(),
      onSearch: (aQuery) => setState(() => _query = aQuery.trim().toLowerCase()),
      actions: [
        IconButton(tooltip: 'family.join_by_code'.tr(), icon: const Icon(AppIcons.keyRound), onPressed: actions.joinByCode),
      ],
      child: ListView(
        key: const PageStorageKey('list.groups'),
        padding: screenPadding(aContext),
        children: [GroupsBlock(actions: actions, isFramed: false, query: _query)],
      ),
    );
  }
}
