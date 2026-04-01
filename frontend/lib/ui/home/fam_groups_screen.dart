import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:go_router/go_router.dart';
import '../../providers/api_prov.dart';
import 'fam_groups_grid.dart';

class FamGroupsScreen extends ConsumerWidget {
  const FamGroupsScreen({super.key});

  Future<void> _handleDelete(BuildContext context, WidgetRef ref, String id) async {
    try {
      await ref.read(apiProv).deleteFam(id);
      ref.invalidate(famsProv);
    } catch (_) {}
  }

  Future<void> _handleLeave(BuildContext context, WidgetRef ref, String id) async {
    try {
      await ref.read(apiProv).leaveFam(id);
      ref.invalidate(famsProv);
    } catch (e) {
      if (e is DioException && e.response?.data['error'] == 'CANNOT_LEAVE_LAST_ADMIN') {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('family.leave_last_admin_err'.tr()),
              backgroundColor: Colors.red.shade800,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final famsAsync = ref.watch(famsProv);

    return famsAsync.when(
      data: (fams) => FamGroupsGrid(
        fams: fams,
        onCreateFam: () => context.go('/app/families/new'),
        onSelectFam: (id) => context.go('/app/families/$id'),
        onDeleteFam: (id) => _handleDelete(context, ref, id),
        onLeaveFam: (id) => _handleLeave(context, ref, id),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text(err.toString())),
    );
  }
}