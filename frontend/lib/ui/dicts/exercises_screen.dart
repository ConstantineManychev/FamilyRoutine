import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class ExercisesScreen extends ConsumerStatefulWidget {
  const ExercisesScreen({super.key});

  @override
  ConsumerState<ExercisesScreen> createState() => _ExercisesScreenState();
}

class _ExercisesScreenState extends ConsumerState<ExercisesScreen> {
  List<ExDto> _exs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final res = await ref.read(apiProv).getExercises();
      if (mounted) setState(() => _exs = res);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('exercises.title'.tr()),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            onPressed: () => context.go('/app/exercises/new'),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _exs.isEmpty
              ? Center(child: Text('common.no_data'.tr()))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _exs.length,
                  itemBuilder: (context, index) {
                    final ex = _exs[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        leading: const Icon(LucideIcons.activity, color: Colors.blue),
                        title: Text(ex.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('${'exercises.types.${ex.exType}'.tr()} | MET: ${ex.metVal}'),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () => context.go('/app/exercises/${ex.id}'),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.go('/app/exercises/new'),
        child: const Icon(LucideIcons.plus),
      ),
    );
  }
}