// lib/auth_service.dart
//
// Google sign-in for the Breathe app, talking to the Flask server.
// Start the app with a plain `flutter run` (or the Run button). No extra flags needed.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class AuthService {
  // Cloudflare quick-tunnel address. It changes whenever cloudflared restarts:
  // if the app suddenly can't connect, update this line and rebuild.
  static const _apiBase = 'https://hope-trains-licensed-prospective.trycloudflare.com';

  // WEB client ID (not a secret, safe to keep in the app)
  static const _webClientId =
      '57786411672-hfmm3t0jlc1pthdb1ch2a5u2iag1021p.apps.googleusercontent.com';

  /// Server address, so other files can use the same one: AuthService.apiBase
  static String get apiBase => _apiBase;

  static const _timeout = Duration(seconds: 15);
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kUserId = 'user_id';

  final _storage = const FlutterSecureStorage();
  final _google = GoogleSignIn.instance;

  // Stops two requests from refreshing at the same time (each refresh token works once)
  Future<bool>? _refreshing;

  /// MUST be called once in main() before runApp(): `await auth.init();`
  Future<void> init() async {
    await _google.initialize(serverClientId: _webClientId);
  }

  /// True if a saved session still works. Use at app start to skip the login screen.
  Future<bool> restoreSession() async {
    final refreshToken = await _storage.read(key: _kRefresh);
    if (refreshToken == null) return false;
    return refresh();
  }

  /// Opens Google sign-in, then exchanges the Google ID token for our own tokens.
  Future<void> signInWithGoogle() async {
    final GoogleSignInAccount account;
    try {
      account = await _google.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw AuthException('Sign-in cancelled');
      }
      throw AuthException('Google sign-in failed: ${e.code.name} ${e.description ?? ''}');
    }

    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw AuthException('Google returned no ID token. Check the WEB client ID.');
    }

    final res = await http
        .post(
          Uri.parse('$_apiBase/auth/google'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'id_token': idToken}),
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw AuthException('Server login failed (${res.statusCode}): ${res.body}');
    }
    await _saveTokens(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// The signed-in user's id, used as <user_id> in /api/users/<user_id>/... calls.
  /// If it was never saved (e.g. older login), it is fetched from /api/me once.
  Future<String?> get userId async {
    final saved = await _storage.read(key: _kUserId);
    if (saved != null) return saved;
    if (!await isSignedIn) return null;

    final res = await authedGet('/api/me');
    if (res.statusCode != 200) return null;
    final id = (jsonDecode(res.body) as Map<String, dynamic>)['user']?['id'] as String?;
    if (id != null) await _storage.write(key: _kUserId, value: id);
    return id;
  }

  /// Gets a new access token. Returns false if the user must sign in again.
  Future<bool> refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final refreshToken = await _storage.read(key: _kRefresh);
    if (refreshToken == null) return false;

    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('$_apiBase/auth/refresh'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh_token': refreshToken}),
          )
          .timeout(_timeout);
    } on Exception {
      // Network problem (e.g. off home Wi-Fi): keep tokens, try again later
      return false;
    }

    if (res.statusCode == 401) {
      await _clearLocal(); // token revoked or expired: real sign-out
      return false;
    }
    if (res.statusCode != 200) return false;

    await _saveTokens(jsonDecode(res.body) as Map<String, dynamic>);
    return true;
  }

  Future<http.Response> authedGet(String path) =>
      _authed((h) => http.get(Uri.parse('$_apiBase$path'), headers: h));

  Future<http.Response> authedPost(String path, Object body) => _authed((h) => http.post(
        Uri.parse('$_apiBase$path'),
        headers: {...h, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ));

  Future<http.Response> authedPatch(String path, Object body) => _authed((h) => http.patch(
        Uri.parse('$_apiBase$path'),
        headers: {...h, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ));

  Future<http.Response> authedPut(String path, Object body) => _authed((h) => http.put(
        Uri.parse('$_apiBase$path'),
        headers: {...h, 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ));

  Future<http.Response> authedDelete(String path) =>
      _authed((h) => http.delete(Uri.parse('$_apiBase$path'), headers: h));

  Future<http.Response> _authed(
      Future<http.Response> Function(Map<String, String> headers) send) async {
    Future<http.Response> attempt() async {
      final token = await _storage.read(key: _kAccess);
      if (token == null) throw AuthException('Not signed in');
      return send({'Authorization': 'Bearer $token'}).timeout(_timeout);
    }

    var res = await attempt();
    if (res.statusCode == 401 && await refresh()) {
      res = await attempt();
    }
    return res;
  }

  Future<bool> get isSignedIn async => (await _storage.read(key: _kRefresh)) != null;

  /// Revokes the refresh token on the server, then clears everything locally.
  Future<void> signOut() async {
    final refreshToken = await _storage.read(key: _kRefresh);
    if (refreshToken != null) {
      try {
        await http
            .post(
              Uri.parse('$_apiBase/auth/logout'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refresh_token': refreshToken}),
            )
            .timeout(_timeout);
      } on Exception {
        // Server unreachable: still sign out locally
      }
    }
    await _clearLocal();
    await _google.signOut();
  }

  Future<void> _saveTokens(Map<String, dynamic> t) async {
    await _storage.write(key: _kAccess, value: t['access_token'] as String);
    await _storage.write(key: _kRefresh, value: t['refresh_token'] as String);
    if (t['user_id'] != null) {
      await _storage.write(key: _kUserId, value: t['user_id'] as String);
    }
  }

  Future<void> _clearLocal() async {
    await _storage.delete(key: _kAccess);
    await _storage.delete(key: _kRefresh);
    await _storage.delete(key: _kUserId);
  }
}