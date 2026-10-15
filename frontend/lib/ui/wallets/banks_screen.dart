import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/api_prov.dart';
import '../common/feedback.dart';
import '../common/page_frames.dart';
import 'bank_conns_section.dart';

class BanksScreen extends ConsumerStatefulWidget
{
  const BanksScreen({super.key});

  @override
  ConsumerState<BanksScreen> createState() => _BanksScreenState();
}

class _BanksScreenState extends ConsumerState<BanksScreen>
{
  String _query = '';

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    return ListPage(
      title: 'bank.connections'.tr(),
      onAdd: () => connectBank(aContext, ref),
      addTooltip: 'bank.connect'.tr(),
      onSearch: (aQuery) => setState(() => _query = aQuery.trim()),
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(bankConnsProv),
        child: ListView(
          key: const PageStorageKey('list.banks'),
          padding: screenPadding(aContext),
          children: [BankConnsSection(query: _query, isHeaderVisible: false)],
        ),
      ),
    );
  }
}
