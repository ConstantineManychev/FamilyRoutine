import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';
import '../../providers/api_prov.dart';
import '../../providers/auth_provider.dart';
import '../common/feedback.dart';
import '../widgets/lang_selector.dart';

const int minPasswordLength = 10;
const int maxPasswordLength = 128;
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

class AuthScreen extends ConsumerStatefulWidget
{
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen>
{
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _fNameCtrl = TextEditingController();
  final _lNameCtrl = TextEditingController();
  final _bDateCtrl = TextEditingController();

  bool _isLogin = true;
  bool _isBusy = false;
  DateTime? _bDate;

  @override
  void dispose()
  {
    _emailCtrl.dispose();
    _pwdCtrl.dispose();
    _fNameCtrl.dispose();
    _lNameCtrl.dispose();
    _bDateCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBDate() async
  {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _bDate ?? DateTime(now.year - 20, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
    );

    if (picked != null && mounted)
    {
      setState(()
      {
        _bDate = picked;
        _bDateCtrl.text = DateFormat('yyyy-MM-dd').format(picked);
      });
    }
  }

  void _switchMode(bool aIsLogin)
  {
    setState(()
    {
      _isLogin = aIsLogin;
      _formKey.currentState?.reset();
    });
  }

  Future<void> _submit() async
  {
    if (_isBusy || !(_formKey.currentState?.validate() ?? false))
    {
      return;
    }

    setState(() => _isBusy = true);

    try
    {
      if (_isLogin)
      {
        await ref.read(authProv.notifier).login(_emailCtrl.text.trim(), _pwdCtrl.text);
        return;
      }

      await ref.read(apiProv).register(RegisterData(
        fName: _fNameCtrl.text.trim(),
        lName: _lNameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        password: _pwdCtrl.text,
        birthDate: _bDateCtrl.text,
      ));

      if (!mounted)
      {
        return;
      }

      setState(()
      {
        _isLogin = true;
        _fNameCtrl.clear();
        _lNameCtrl.clear();
        _bDateCtrl.clear();
        _pwdCtrl.clear();
        _bDate = null;
      });
      showInfoSnack(context, 'auth.reg_success'.tr());
    }
    catch (aError)
    {
      if (mounted)
      {
        showErrorSnack(context, aError);
      }
    }
    finally
    {
      if (mounted)
      {
        setState(() => _isBusy = false);
      }
    }
  }

  String? _validateRequired(String? aValue)
  {
    return (aValue == null || aValue.trim().isEmpty) ? 'validation.required'.tr() : null;
  }

  String? _validateEmail(String? aValue)
  {
    final value = aValue?.trim() ?? '';
    return _emailPattern.hasMatch(value) ? null : 'validation.email'.tr();
  }

  String? _validatePassword(String? aValue)
  {
    final value = aValue ?? '';

    if (_isLogin)
    {
      return value.isEmpty ? 'validation.required'.tr() : null;
    }

    if (value.length < minPasswordLength || value.length > maxPasswordLength)
    {
      return 'validation.password_len'.tr(namedArgs: {'min': '$minPasswordLength'});
    }

    return null;
  }

  @override
  Widget build(BuildContext aContext)
  {
    aContext.locale;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: const [
          Padding(padding: EdgeInsets.only(right: 16.0), child: LangSelector()),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 380),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 20)],
            ),
            child: Form(
              key: _formKey,
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTabs(),
                    const SizedBox(height: 32),
                    if (!_isLogin) ..._buildRegFields(),
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(labelText: 'auth.email'.tr()),
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _pwdCtrl,
                      obscureText: true,
                      autofillHints: [_isLogin ? AutofillHints.password : AutofillHints.newPassword],
                      inputFormatters: [LengthLimitingTextInputFormatter(maxPasswordLength)],
                      decoration: InputDecoration(
                        labelText: 'auth.pwd'.tr(),
                        helperText: _isLogin
                            ? null
                            : 'validation.password_len'.tr(namedArgs: {'min': '$minPasswordLength'}),
                      ),
                      validator: _validatePassword,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _isBusy ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                        ),
                        child: _isBusy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text('auth.submit'.tr()),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabs()
  {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton(
          onPressed: () => _switchMode(true),
          child: Text(
            'auth.login_tab'.tr(),
            style: TextStyle(fontWeight: _isLogin ? FontWeight.bold : FontWeight.normal),
          ),
        ),
        const SizedBox(width: 16),
        TextButton(
          onPressed: () => _switchMode(false),
          child: Text(
            'auth.reg_tab'.tr(),
            style: TextStyle(fontWeight: !_isLogin ? FontWeight.bold : FontWeight.normal),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildRegFields()
  {
    return [
      TextFormField(
        controller: _fNameCtrl,
        autofillHints: const [AutofillHints.givenName],
        inputFormatters: [LengthLimitingTextInputFormatter(100)],
        decoration: InputDecoration(labelText: 'auth.f_name'.tr()),
        validator: _validateRequired,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _lNameCtrl,
        autofillHints: const [AutofillHints.familyName],
        inputFormatters: [LengthLimitingTextInputFormatter(100)],
        decoration: InputDecoration(labelText: 'auth.l_name'.tr()),
        validator: _validateRequired,
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: _bDateCtrl,
        readOnly: true,
        onTap: _pickBDate,
        decoration: InputDecoration(
          labelText: 'auth.b_date'.tr(),
          suffixIcon: const Icon(Icons.calendar_today, size: 20),
        ),
        validator: (aValue) => (aValue == null || aValue.isEmpty) ? 'auth.err_empty_bdate'.tr() : null,
      ),
      const SizedBox(height: 16),
    ];
  }
}
