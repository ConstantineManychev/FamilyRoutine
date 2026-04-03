import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:go_router/go_router.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../widgets/lang_selector.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _isLogin = true;
  DateTime? _bDate;
  
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _fNameCtrl = TextEditingController();
  final _lNameCtrl = TextEditingController();
  final _bDateCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _pwdCtrl.dispose();
    _fNameCtrl.dispose();
    _lNameCtrl.dispose();
    _bDateCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
    );

    if (picked != null) {
      setState(() {
        _bDate = picked;
        _bDateCtrl.text = DateFormat('yyyy-MM-dd').format(picked);
      });
    }
  }

  void _showSnack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _submit() async {
    if (!_isLogin && _bDate == null) {
      _showSnack('auth.err_empty_bdate'.tr());
      return;
    }

    try {
      final api = ref.read(apiProv);
      if (_isLogin) {
        await api.post('/api/auth/login', data: {
          'email': _emailCtrl.text,
          'password': _pwdCtrl.text,
        });
        ref.read(authStateProvider.notifier).setLoggedIn();
      } else {
        await api.post('/api/auth/register', data: {
          'first_name': _fNameCtrl.text,
          'last_name': _lNameCtrl.text,
          'email': _emailCtrl.text,
          'password': _pwdCtrl.text,
          'birth_date': _bDateCtrl.text,
        });
      }
      if (mounted) context.go('/app');
    } catch (e) {
      _showSnack('auth.err_auth'.tr());
    }
  }

  @override
  Widget build(BuildContext context) {
    context.locale;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16.0),
            child: LangSelector(),
          ),
        ],
      ),
      body: Center(
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 20,
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildTabs(),
              const SizedBox(height: 32),
              if (!_isLogin) ..._buildRegFields(),
              _buildAuthFields(),
              const SizedBox(height: 32),
              _buildSubmitBtn(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabs() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton(
          onPressed: () => setState(() => _isLogin = true),
          child: Text(
            'auth.login_tab'.tr(),
            style: TextStyle(fontWeight: _isLogin ? FontWeight.bold : FontWeight.normal),
          ),
        ),
        const SizedBox(width: 16),
        TextButton(
          onPressed: () => setState(() => _isLogin = false),
          child: Text(
            'auth.reg_tab'.tr(),
            style: TextStyle(fontWeight: !_isLogin ? FontWeight.bold : FontWeight.normal),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRegFields() {
    return [
      TextField(
        controller: _fNameCtrl,
        decoration: InputDecoration(labelText: 'auth.f_name'.tr()),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _lNameCtrl,
        decoration: InputDecoration(labelText: 'auth.l_name'.tr()),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _bDateCtrl,
        readOnly: true,
        onTap: _pickBDate,
        decoration: InputDecoration(
          labelText: 'auth.b_date'.tr(),
          suffixIcon: const Icon(Icons.calendar_today, size: 20),
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  Widget _buildAuthFields() {
    return Column(
      children: [
        TextField(
          controller: _emailCtrl,
          decoration: InputDecoration(labelText: 'auth.email'.tr()),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwdCtrl,
          obscureText: true,
          decoration: InputDecoration(labelText: 'auth.pwd'.tr()),
        ),
      ],
    );
  }

  Widget _buildSubmitBtn() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: _submit,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2563EB),
          foregroundColor: Colors.white,
        ),
        child: Text('auth.submit'.tr()),
      ),
    );
  }
}