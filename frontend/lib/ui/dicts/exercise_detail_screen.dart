import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:uuid/uuid.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class ExerciseDetailScreen extends ConsumerStatefulWidget {
  final String? exId;
  final VoidCallback onSaved;

  const ExerciseDetailScreen({super.key, this.exId, required this.onSaved});

  @override
  ConsumerState<ExerciseDetailScreen> createState() => _ExerciseDetailScreenState();
}

class _ExerciseDetailScreenState extends ConsumerState<ExerciseDetailScreen> {
  final _nameCtrl = TextEditingController();
  final _metCtrl = TextEditingController();
  final _bwPctCtrl = TextEditingController();
  
  String _selType = 'strength';
  String _selWeightType = 'external';
  
  final List<String> _types = ['cardio', 'strength', 'flexibility', 'mixed'];
  final List<String> _weightTypes = ['external', 'hybrid', 'bodyweight'];
  final List<String> _availMuscles = ['chest', 'back', 'legs', 'shoulders', 'arms', 'core', 'full_body', 'cardio'];
  
  List<ExMuscleDto> _muscles = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _bwPctCtrl.text = '0';
    _initData();
  }

  Future<void> _initData() async {
    if (widget.exId == null) return;
    setState(() => _isLoading = true);
    try {
      final ex = await ref.read(apiProv).getExerciseDetail(widget.exId!);
      _nameCtrl.text = ex.name;
      _metCtrl.text = ex.metVal.toString();
      _selType = ex.exType;
      _selWeightType = ex.weightType;
      _bwPctCtrl.text = ex.bwPct.toString();
      _muscles = ex.muscles;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _addMuscleRow() {
    setState(() {
      _muscles.add(ExMuscleDto(muscle: _availMuscles.first, pct: 100));
    });
  }

  Future<void> _delete() async {
    final conf = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('common.delete_confirm'.tr()),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('common.no'.tr())),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true), 
            child: Text('common.yes'.tr())
          ),
        ],
      ),
    );

    if (conf == true) {
      setState(() => _isLoading = true);
      try {
        await ref.read(apiProv).deleteExercise(widget.exId!);
        widget.onSaved();
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (_nameCtrl.text.trim().isEmpty) return;
    
    final met = double.tryParse(_metCtrl.text.trim());
    if (met == null || met <= 0) return;

    final bwPct = double.tryParse(_bwPctCtrl.text.trim()) ?? 0.0;

    if (_muscles.isEmpty) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('common.error'.tr()),
          content: Text('exercises.err_no_muscles'.tr()),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: Text('common.ok'.tr()))],
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final dto = ExDto(
        id: widget.exId ?? const Uuid().v4(),
        name: _nameCtrl.text.trim(),
        exType: _selType,
        metVal: met,
        isCustom: true,
        weightType: _selWeightType,
        bwPct: bwPct,
        muscles: _muscles,
      );

      if (widget.exId == null) {
        await ref.read(apiProv).createExercise(dto);
      } else {
        await ref.read(apiProv).updateExercise(widget.exId!, dto);
      }
      widget.onSaved();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('exercises.err_save'.tr())));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showBwField = _selWeightType == 'hybrid' || _selWeightType == 'bodyweight';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.exId == null ? 'exercises.add'.tr() : 'exercises.edit'.tr()),
        actions: [
          if (widget.exId != null)
            IconButton(icon: const Icon(LucideIcons.trash, color: Colors.red), onPressed: _delete),
          IconButton(icon: const Icon(Icons.save), onPressed: _save)
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                TextField(controller: _nameCtrl, decoration: InputDecoration(labelText: 'exercises.name'.tr(), border: const OutlineInputBorder())),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _selType,
                        decoration: InputDecoration(labelText: 'exercises.type'.tr(), border: const OutlineInputBorder()),
                        items: _types.map((t) => DropdownMenuItem(value: t, child: Text('exercises.types.$t'.tr()))).toList(),
                        onChanged: (v) => setState(() => _selType = v!),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        controller: _metCtrl,
                        decoration: InputDecoration(labelText: 'exercises.met'.tr(), border: const OutlineInputBorder()),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        value: _selWeightType,
                        decoration: InputDecoration(labelText: 'exercises.weight_type'.tr(), border: const OutlineInputBorder()),
                        items: _weightTypes.map((t) => DropdownMenuItem(value: t, child: Text('exercises.w_types.$t'.tr()))).toList(),
                        onChanged: (v) {
                          setState(() {
                            _selWeightType = v!;
                            if (v == 'external') _bwPctCtrl.text = '0';
                            if (v == 'bodyweight') _bwPctCtrl.text = '100';
                          });
                        },
                      ),
                    ),
                    if (showBwField) ...[
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _bwPctCtrl,
                          decoration: InputDecoration(labelText: 'exercises.bw_pct'.tr(), border: const OutlineInputBorder()),
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        ),
                      ),
                    ]
                  ],
                ),
                const SizedBox(height: 32),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('exercises.muscles'.tr(), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    TextButton.icon(
                      onPressed: _addMuscleRow,
                      icon: const Icon(LucideIcons.plus),
                      label: Text('exercises.add_muscle'.tr()),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._muscles.asMap().entries.map((e) {
                  final idx = e.key;
                  final m = e.value;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            value: m.muscle,
                            decoration: const InputDecoration(border: OutlineInputBorder()),
                            items: _availMuscles.map((t) => DropdownMenuItem(value: t, child: Text('exercises.muscle_grps.$t'.tr()))).toList(),
                            onChanged: (v) => setState(() => _muscles[idx] = ExMuscleDto(muscle: v!, pct: m.pct)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 1,
                          child: TextFormField(
                            initialValue: m.pct.toString(),
                            decoration: InputDecoration(labelText: 'exercises.pct'.tr(), border: const OutlineInputBorder()),
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            onChanged: (v) {
                              final p = double.tryParse(v) ?? m.pct;
                              _muscles[idx] = ExMuscleDto(muscle: m.muscle, pct: p);
                            },
                          ),
                        ),
                        IconButton(
                          icon: const Icon(LucideIcons.trash, color: Colors.red),
                          onPressed: () => setState(() => _muscles.removeAt(idx)),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
    );
  }
}