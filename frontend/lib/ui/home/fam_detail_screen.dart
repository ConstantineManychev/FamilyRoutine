import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../domain/models.dart';
import '../../providers/api_prov.dart';

class _LocalMem {
  final String email;
  String role;
  _LocalMem(this.email, this.role);
}

class FamDetailScreen extends ConsumerStatefulWidget {
  final String? famId;
  final VoidCallback onSaved;

  const FamDetailScreen({super.key, this.famId, required this.onSaved});

  @override
  ConsumerState<FamDetailScreen> createState() => _FamDetailScreenState();
}

class _FamDetailScreenState extends ConsumerState<FamDetailScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  
  FamDetailDto? _famData;
  final List<_LocalMem> _newMems = [];
  bool _isLoading = true;
  String? _currUserId;
  bool _isAdmin = false;

  bool get _isEdit => widget.famId != null;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    setState(() => _isLoading = true);
    try {
      try {
        final prof = await ref.read(profProv.future);
        _currUserId = prof.id;
      } catch (_) {}

      if (_isEdit) {
        _famData = await ref.read(apiProv).getFamDetails(widget.famId!);
        _nameCtrl.text = _famData!.name;

        if (_currUserId != null) {
          _isAdmin = _famData!.members.any((m) => 
            m.id.toLowerCase() == _currUserId!.toLowerCase() && 
            m.role.toLowerCase() == 'admin'
          );
        }

        if (!_isAdmin) {
          try {
            final fams = await ref.read(apiProv).getFams();
            final currentFam = fams.firstWhere((f) => f.id == widget.famId);
            _isAdmin = currentFam.role.toLowerCase() == 'admin';
          } catch (_) {}
        }
      } else {
        _isAdmin = true;
      }
    } catch (e) {
      _showErr('family.err_load');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showErr(String key) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(key.tr()), backgroundColor: Colors.red.shade800)
      );
    }
  }

  Future<void> _saveBaseInfo() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;

    setState(() => _isLoading = true);
    try {
      if (!_isEdit) {
        final memData = _newMems.map((m) => {'email': m.email, 'role': m.role}).toList();
        await ref.read(apiProv).createFam(name, memData);
        widget.onSaved();
      } else {
        await ref.read(apiProv).updateFamName(widget.famId!, name);
        ref.invalidate(famsProv);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('common.saved'.tr())));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addMem() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) return;

    if (!_isEdit) {
      if (!_newMems.any((m) => m.email.toLowerCase() == email.toLowerCase())) {
        setState(() {
          _newMems.add(_LocalMem(email, 'standard'));
          _emailCtrl.clear();
        });
      }
      return;
    }

    setState(() => _isLoading = true);
    try {
      await ref.read(apiProv).addFamMember(widget.famId!, email, 'standard');
      _emailCtrl.clear();
      await _loadInitialData();
    } catch (e) {
      _showErr('family.err_user_not_found');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _updateMemRole(String userId, String role) async {
    setState(() => _isLoading = true);
    try {
      await ref.read(apiProv).updateFamMemberRole(widget.famId!, userId, role);
      await _loadInitialData();
    } catch (e) {
      if (e is DioException && e.response?.data['error'] == 'CANNOT_LEAVE_LAST_ADMIN') {
        _showErr('family.leave_last_admin_err');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _removeMem(String userId) async {
    setState(() => _isLoading = true);
    try {
      await ref.read(apiProv).removeFamMember(widget.famId!, userId);
      await _loadInitialData();
    } catch (e) {
      if (e is DioException && e.response?.data['error'] == 'CANNOT_LEAVE_LAST_ADMIN') {
        _showErr('family.leave_last_admin_err');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _famData == null && _isEdit) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 32),
            TextField(
              controller: _nameCtrl,
              enabled: _isAdmin,
              decoration: InputDecoration(
                labelText: 'family.group_name'.tr(),
                border: const OutlineInputBorder()
              ),
            ),
            const SizedBox(height: 32),
            if (_isAdmin) ...[
              _buildAddMemberField(),
              const SizedBox(height: 24),
            ],
            Expanded(child: _buildMembersList()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          _isEdit ? 'family.manage_group'.tr() : 'family.create_group'.tr(),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        if (_isAdmin)
          ElevatedButton.icon(
            onPressed: _saveBaseInfo,
            icon: _isLoading 
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) 
              : const Icon(LucideIcons.save, size: 18),
            label: Text('common.save'.tr()),
          )
      ],
    );
  }

  Widget _buildAddMemberField() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _emailCtrl,
            decoration: InputDecoration(
              labelText: 'family.member_email'.tr(),
              hintText: 'example@mail.com',
              border: const OutlineInputBorder()
            ),
            onSubmitted: (_) => _addMem(),
          ),
        ),
        const SizedBox(width: 16),
        SizedBox(
          height: 56,
          child: ElevatedButton(
            onPressed: _addMem,
            child: const Icon(LucideIcons.plus),
          ),
        ),
      ],
    );
  }

  Widget _buildMembersList() {
    final itemsCount = _isEdit ? (_famData?.members.length ?? 0) : _newMems.length;
    
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8)
      ),
      child: ListView.separated(
        itemCount: itemsCount,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          if (_isEdit) {
            return _buildExistingMemTile(_famData!.members[i]);
          }
          return _buildLocalMemTile(_newMems[i]);
        },
      ),
    );
  }

  Widget _buildExistingMemTile(FamMemberDto m) {
    final bool isMe = _currUserId != null && m.id.toLowerCase() == _currUserId!.toLowerCase();
    
    return ListTile(
      leading: CircleAvatar(child: Text(m.fName.isNotEmpty ? m.fName[0] : '?')),
      title: Text('${m.fName} ${m.lName}'),
      subtitle: Text(m.role.toUpperCase(), style: TextStyle(color: m.role.toLowerCase() == 'admin' ? Colors.blue : Colors.grey)),
      trailing: _isAdmin && !isMe ? _buildRoleMenu(m.role, (val) {
        if (val == 'remove') _removeMem(m.id);
        else _updateMemRole(m.id, val);
      }) : null,
    );
  }

  Widget _buildLocalMemTile(_LocalMem m) {
    return ListTile(
      leading: const CircleAvatar(child: Icon(LucideIcons.user)),
      title: Text(m.email),
      subtitle: Text(m.role.toUpperCase(), style: TextStyle(color: m.role.toLowerCase() == 'admin' ? Colors.blue : Colors.grey)),
      trailing: _buildRoleMenu(m.role, (val) {
        if (val == 'remove') setState(() => _newMems.remove(m));
        else setState(() => m.role = val);
      }),
    );
  }

  Widget _buildRoleMenu(String currRole, Function(String) onSelected) {
    return PopupMenuButton<String>(
      onSelected: onSelected,
      itemBuilder: (ctx) => [
        PopupMenuItem(value: 'admin', child: Text('family.make_admin'.tr())),
        PopupMenuItem(value: 'standard', child: Text('family.make_standard'.tr())),
        PopupMenuItem(
          value: 'remove', 
          child: Text('family.remove_member'.tr(), style: const TextStyle(color: Colors.red))
        ),
      ],
    );
  }
}