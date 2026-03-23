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
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _fNameCtrl = TextEditingController();
  final _lNameCtrl = TextEditingController();

  Future<void> _submit() async {
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
        });
      }
      if (mounted) context.go('/app');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('auth.err_auth'.tr())),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _isLogin = true),
                    child: Text(
                      'auth.login_tab'.tr(),
                      style: TextStyle(
                        fontWeight: _isLogin ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: () => setState(() => _isLogin = false),
                    child: Text(
                      'auth.reg_tab'.tr(),
                      style: TextStyle(
                        fontWeight: !_isLogin ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              if (!_isLogin) ...[
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
              ],
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
              const SizedBox(height: 32),
              SizedBox(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}