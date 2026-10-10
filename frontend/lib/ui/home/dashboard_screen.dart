import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../common/feedback.dart';
import '../finance/cashflow_card.dart';

class DashboardScreen extends ConsumerWidget
{
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext aContext, WidgetRef aRef)
  {
    aContext.locale;
    final user = aRef.watch(authProv.select((aState) => aState.user));
    final famsAsync = aRef.watch(famsProv);

    return SingleChildScrollView(
      padding: screenPadding(aContext),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${'dashboard.welcome'.tr()}, ${user?.fName ?? ''}!',
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
          ),
          const SizedBox(height: 32),
          const CashflowCard(),
          const SizedBox(height: 24),
          Container(
            constraints: const BoxConstraints(maxWidth: 300),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'dashboard.active_fams'.tr(),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)),
                ),
                const SizedBox(height: 12),
                famsAsync.when(
                  data: (aFams) => Text(
                    '${aFams.length}',
                    style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Color(0xFF2563EB)),
                  ),
                  loading: () => const CircularProgressIndicator(),
                  error: (aError, _) => Text(errorText(aError)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
