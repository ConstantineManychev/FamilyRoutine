import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_prov.dart';

final authStateProvider = StateNotifierProvider<AuthNotifier, bool>((ref) {
  return AuthNotifier(ref.read(storageProv));
});

class AuthNotifier extends StateNotifier<bool> {
  final FlutterSecureStorage _storage;

  AuthNotifier(this._storage) : super(false) {
    checkAuth();
  }

  Future<void> checkAuth() async {
    final tkn = await _storage.read(key: 'jwt');
    state = tkn != null;
  }

  Future<void> logout() async {
    await _storage.delete(key: 'jwt');
    state = false;
  }

  void setLoggedIn() {
    state = true;
  }
}