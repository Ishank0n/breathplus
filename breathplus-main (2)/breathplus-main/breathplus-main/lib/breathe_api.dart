import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

/// Client for the Breathe Flask API (app.py).
///
/// Every /api/users/... call sends the sign-in token from AuthService and uses
/// the signed-in user's id. Users are created by Google sign-in, not by this file.
///
/// The admin endpoints (POST /api/users, POST/PATCH /api/techniques,
/// PUT /api/techniques/<ref>/phases) are left out on purpose: they need
/// ADMIN_API_KEY, and an admin key must never be shipped inside a mobile app.

/// Where the Flask server lives. Set in ONE place: _apiBase in auth_service.dart.
String get kApiBaseUrl => AuthService.apiBase;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------
class ApiException implements Exception {
  /// HTTP status code. 0 = server unreachable, -1 = unexpected response.
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  bool get isNetworkError => statusCode == 0;

  /// True when the user has to sign in again (send them to the login screen).
  bool get needsSignIn => statusCode == 401;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------
int _int(dynamic v) => (v as num).toInt();
int? _intOrNull(dynamic v) => v == null ? null : (v as num).toInt();
double _double(dynamic v) => (v as num).toDouble();
double? _doubleOrNull(dynamic v) => v == null ? null : (v as num).toDouble();
DateTime? _date(dynamic v) => v == null ? null : DateTime.parse(v as String);

Map<String, dynamic> _obj(dynamic v) {
  if (v is Map) return Map<String, dynamic>.from(v);
  throw const ApiException(-1, 'Unexpected response from the server.');
}

List<Map<String, dynamic>> _objList(dynamic v) {
  if (v == null) return const [];
  if (v is! List) {
    throw const ApiException(-1, 'Unexpected response from the server.');
  }
  return v.map(_obj).toList();
}

/// The API wants ISO-8601 with a timezone, e.g. 2026-10-27T13:09:00Z.
String _isoUtc(DateTime d) =>
    '${d.toUtc().toIso8601String().split('.').first}Z';

// ---------------------------------------------------------------------------
// Models (prefixed with Api so they never clash with names in your pages)
// ---------------------------------------------------------------------------
class ApiPhase {
  final int step;
  final String phase; // inhale | hold_in | exhale | hold_out
  final double durationSec;

  const ApiPhase({
    required this.step,
    required this.phase,
    required this.durationSec,
  });

  /// Session snapshots don't include `step`, so fall back to list position.
  factory ApiPhase.fromJson(Map<String, dynamic> j, int index) => ApiPhase(
        step: _intOrNull(j['step']) ?? index + 1,
        phase: j['phase'] as String,
        durationSec: _double(j['duration_sec']),
      );

  String get label {
    switch (phase) {
      case 'inhale':
        return 'Inhale';
      case 'exhale':
        return 'Exhale';
      case 'hold_in':
      case 'hold_out':
        return 'Hold';
      default:
        return phase;
    }
  }
}

List<ApiPhase> _phases(dynamic v) {
  final items = _objList(v);
  return [
    for (var i = 0; i < items.length; i++) ApiPhase.fromJson(items[i], i),
  ];
}

class ApiPlantProgress {
  final String stage; // not_collected | collected | grown | flourishing
  final int completedSessions;
  final int? progressToNext; // null at the final stage
  final int sessionsPerStage;
  final DateTime? lastCompletedAt;

  const ApiPlantProgress({
    required this.stage,
    required this.completedSessions,
    required this.progressToNext,
    required this.sessionsPerStage,
    required this.lastCompletedAt,
  });

  factory ApiPlantProgress.fromJson(Map<String, dynamic> j) => ApiPlantProgress(
        stage: j['stage'] as String,
        completedSessions: _int(j['completed_sessions']),
        progressToNext: _intOrNull(j['progress_to_next']),
        sessionsPerStage: _int(j['sessions_per_stage']),
        lastCompletedAt: _date(j['last_completed_at']),
      );
}

class ApiTechnique {
  final int id;
  final String slug;
  final String name;
  final String? description;
  final String pattern;
  final List<ApiPhase> phases;
  final double cycleDurationSec;
  final int defaultDurationSec;
  final String? plantKey;
  final int sortOrder;
  final bool isActive;

  /// Only present on /api/users/<id>/techniques.
  final ApiPlantProgress? progress;

  const ApiTechnique({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.pattern,
    required this.phases,
    required this.cycleDurationSec,
    required this.defaultDurationSec,
    required this.plantKey,
    required this.sortOrder,
    required this.isActive,
    required this.progress,
  });

  factory ApiTechnique.fromJson(Map<String, dynamic> j) => ApiTechnique(
        id: _int(j['id']),
        slug: j['slug'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        pattern: j['pattern'] as String,
        phases: _phases(j['phases']),
        cycleDurationSec: _doubleOrNull(j['cycle_duration_sec']) ?? 0,
        defaultDurationSec: _int(j['default_duration_sec']),
        plantKey: j['plant_key'] as String?,
        sortOrder: _int(j['sort_order']),
        isActive: j['is_active'] as bool? ?? true,
        progress: j['progress'] == null
            ? null
            : ApiPlantProgress.fromJson(_obj(j['progress'])),
      );
}

class ApiUser {
  final String id; // public UUID
  final String displayName;
  final String? email;
  final DateTime? createdAt;

  const ApiUser({
    required this.id,
    required this.displayName,
    required this.email,
    required this.createdAt,
  });

  factory ApiUser.fromJson(Map<String, dynamic> j) => ApiUser(
        id: j['id'] as String,
        displayName: j['display_name'] as String,
        email: j['email'] as String?,
        createdAt: _date(j['created_at']),
      );
}

class ApiSession {
  final String id; // public UUID
  final int techniqueId;
  final String techniqueSlug;
  final String techniqueName;
  final String? techniquePlantKey;
  final String status; // in_progress | completed | abandoned
  final String pattern;
  final List<ApiPhase> phases;
  final int targetDurationSec;
  final int elapsedSec;
  final int remainingSec;
  final double progressPct;
  final int cyclesCompleted;
  final double? accuracyPct;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? updatedAt;

  /// From /last-session; elsewhere derived from status.
  final bool canContinue;

  const ApiSession({
    required this.id,
    required this.techniqueId,
    required this.techniqueSlug,
    required this.techniqueName,
    required this.techniquePlantKey,
    required this.status,
    required this.pattern,
    required this.phases,
    required this.targetDurationSec,
    required this.elapsedSec,
    required this.remainingSec,
    required this.progressPct,
    required this.cyclesCompleted,
    required this.accuracyPct,
    required this.startedAt,
    required this.completedAt,
    required this.updatedAt,
    required this.canContinue,
  });

  bool get isInProgress => status == 'in_progress';
  bool get isCompleted => status == 'completed';

  factory ApiSession.fromJson(Map<String, dynamic> j) {
    final t = _obj(j['technique']);
    final status = j['status'] as String;
    return ApiSession(
      id: j['id'] as String,
      techniqueId: _int(t['id']),
      techniqueSlug: t['slug'] as String,
      techniqueName: t['name'] as String,
      techniquePlantKey: t['plant_key'] as String?,
      status: status,
      pattern: j['pattern'] as String,
      phases: _phases(j['phases']),
      targetDurationSec: _int(j['target_duration_sec']),
      elapsedSec: _int(j['elapsed_sec']),
      remainingSec: _int(j['remaining_sec']),
      progressPct: _double(j['progress_pct']),
      cyclesCompleted: _int(j['cycles_completed']),
      accuracyPct: _doubleOrNull(j['accuracy_pct']),
      startedAt: _date(j['started_at']),
      completedAt: _date(j['completed_at']),
      updatedAt: _date(j['updated_at']),
      canContinue: j['can_continue'] as bool? ?? status == 'in_progress',
    );
  }
}

class ApiSessionHistory {
  final int total;
  final int limit;
  final int offset;
  final List<ApiSession> sessions;

  const ApiSessionHistory({
    required this.total,
    required this.limit,
    required this.offset,
    required this.sessions,
  });
}

class ApiSummary {
  final ApiUser user;
  final int currentStreakDays;
  final bool practicedToday;
  final int totalCompletedSessions;
  final int totalPracticeSec;
  final double? averageAccuracyPct;

  const ApiSummary({
    required this.user,
    required this.currentStreakDays,
    required this.practicedToday,
    required this.totalCompletedSessions,
    required this.totalPracticeSec,
    required this.averageAccuracyPct,
  });

  factory ApiSummary.fromJson(Map<String, dynamic> j) => ApiSummary(
        user: ApiUser.fromJson(_obj(j['user'])),
        currentStreakDays: _int(j['current_streak_days']),
        practicedToday: j['practiced_today'] as bool? ?? false,
        totalCompletedSessions: _int(j['total_completed_sessions']),
        totalPracticeSec: _int(j['total_practice_sec']),
        averageAccuracyPct: _doubleOrNull(j['average_accuracy_pct']),
      );
}

/// What SessionPage hands back when it closes:
///   Navigator.of(context).pop(BreatheSessionResult(elapsedSec: ..., completed: true));
/// The home screen saves it to the server.
class BreatheSessionResult {
  /// TOTAL seconds practised in this session, including earlier sittings
  /// when the session was resumed (widget.technique.elapsedSec + this sitting).
  final int elapsedSec;
  final int? cyclesCompleted;
  final double? accuracyPct; // 0-100
  final bool completed;
  final bool abandoned;

  const BreatheSessionResult({
    required this.elapsedSec,
    this.cyclesCompleted,
    this.accuracyPct,
    this.completed = false,
    this.abandoned = false,
  });
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------
class BreatheApi {
  BreatheApi._();
  static final BreatheApi instance = BreatheApi._();

  static const Duration _timeout = Duration(seconds: 10);
  static const String _legacyUserIdKey = 'breathe_user_id'; // pre-sign-in id, no longer used
  static const int maxSessionSec = 4 * 60 * 60; // matches MAX_SESSION_SEC

  final http.Client _client = http.Client();
  final AuthService _auth = AuthService.instance;
  String? _userId;

  /// Last known signed-in user id (null until ensureUser() has run).
  String? get currentUserId => _userId;

  String _seg(String value) => Uri.encodeComponent(value);

  /// Sends a request. With [authed] (the default) it adds the sign-in token,
  /// and on a 401 refreshes the token once and retries.
  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool authed = true,
  }) async {
    var uri = Uri.parse('$kApiBaseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }

    // An http.Request can only be sent once, so build a fresh one per attempt.
    Future<http.Response> send(String? token) async {
      final req = http.Request(method, uri);
      req.headers['Accept'] = 'application/json';
      if (token != null) req.headers['Authorization'] = 'Bearer $token';
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      final streamed = await _client.send(req).timeout(_timeout);
      return http.Response.fromStream(streamed).timeout(_timeout);
    }

    http.Response res;
    try {
      String? token;
      if (authed) {
        token = await _auth.accessToken;
        if (token == null) {
          throw const ApiException(401, 'You are signed out. Please sign in again.');
        }
      }
      res = await send(token);
      if (authed && res.statusCode == 401 && await _auth.refresh()) {
        res = await send(await _auth.accessToken);
      }
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(0, 'The server at $kApiBaseUrl did not respond in time.');
    } on Exception {
      throw ApiException(
        0,
        'Could not reach the server at $kApiBaseUrl. Check your internet '
        'connection and that the server is running.',
      );
    }

    dynamic data;
    if (res.bodyBytes.isNotEmpty) {
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } on FormatException {
        data = null;
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return data;

    if (res.statusCode == 401 && authed) {
      _userId = null;
      throw const ApiException(401, 'Your session has expired. Please sign in again.');
    }

    final message = (data is Map && data['error'] is String)
        ? data['error'] as String
        : 'Request failed with status ${res.statusCode}.';
    throw ApiException(res.statusCode, message);
  }

  // ---- Health (public) -----------------------------------------------------
  Future<bool> health() async {
    final data = _obj(await _request('GET', '/api/health', authed: false));
    return data['status'] == 'ok';
  }

  // ---- Techniques (public) -------------------------------------------------
  Future<List<ApiTechnique>> listTechniques({bool includeInactive = false}) async {
    final data = _obj(await _request(
      'GET',
      '/api/techniques',
      query: includeInactive ? {'include_inactive': 'true'} : null,
      authed: false,
    ));
    return _objList(data['techniques'])
        .map((j) => ApiTechnique.fromJson(j))
        .toList();
  }

  /// [ref] is the numeric id or the slug.
  Future<ApiTechnique> getTechnique(String ref) async {
    final data = _obj(
        await _request('GET', '/api/techniques/${_seg(ref)}', authed: false));
    return ApiTechnique.fromJson(_obj(data['technique']));
  }

  // ---- Users ---------------------------------------------------------------
  Future<ApiUser> getUser(String userId) async {
    final data = _obj(await _request('GET', '/api/users/${_seg(userId)}'));
    return ApiUser.fromJson(_obj(data['user']));
  }

  /// Returns the signed-in user's id. Throws ApiException(401) if signed out.
  /// ([displayName] is ignored now; kept so existing callers still compile.)
  Future<String> ensureUser({String displayName = 'Breathe user'}) async {
    // Read every time so switching Google accounts never uses a stale id.
    final id = await _auth.userId;
    if (id == null || id.isEmpty) {
      _userId = null;
      throw const ApiException(401, 'You are signed out. Please sign in again.');
    }
    _userId = id;
    return id;
  }

  /// Clears the cached id and the old pre-sign-in id. Call after signing out.
  Future<void> resetLocalUser() async {
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legacyUserIdKey);
  }

  Future<ApiUser> getCurrentUser() async => getUser(await ensureUser());

  // ---- Home screen ---------------------------------------------------------
  /// Techniques with this user's plant progress.
  Future<List<ApiTechnique>> listUserTechniques() async {
    final uid = await ensureUser();
    final data =
        _obj(await _request('GET', '/api/users/${_seg(uid)}/techniques'));
    return _objList(data['techniques'])
        .map((j) => ApiTechnique.fromJson(j))
        .toList();
  }

  Future<ApiSummary> getSummary() async {
    final uid = await ensureUser();
    final data = _obj(await _request('GET', '/api/users/${_seg(uid)}/summary'));
    return ApiSummary.fromJson(data);
  }

  // ---- Last session --------------------------------------------------------
  Future<ApiSession?> getLastSession() async {
    final uid = await ensureUser();
    final data =
        _obj(await _request('GET', '/api/users/${_seg(uid)}/last-session'));
    final last = data['last_session'];
    return last == null ? null : ApiSession.fromJson(_obj(last));
  }

  Future<ApiSession> setLastSession(String sessionId) async {
    final uid = await ensureUser();
    final data = _obj(await _request(
      'PUT',
      '/api/users/${_seg(uid)}/last-session',
      body: {'session_id': sessionId},
    ));
    return ApiSession.fromJson(_obj(data['last_session']));
  }

  /// Hides the "Continue last session" card. The session stays in history.
  Future<void> hideLastSession() async {
    final uid = await ensureUser();
    await _request('DELETE', '/api/users/${_seg(uid)}/last-session');
  }

  // ---- Sessions ------------------------------------------------------------
  /// Starts an in-progress session. The server abandons any other
  /// in-progress session for this user and points "last session" at this one.
  Future<ApiSession> startSession(String techniqueRef, {int? targetDurationSec}) async {
    final uid = await ensureUser();
    final data = _obj(await _request(
      'POST',
      '/api/users/${_seg(uid)}/sessions',
      body: {
        'technique': techniqueRef,
        'status': 'in_progress',
        if (targetDurationSec != null)
          'target_duration_sec': targetDurationSec.clamp(30, maxSessionSec),
      },
    ));
    return ApiSession.fromJson(_obj(data['session']));
  }

  /// Logs a session that already finished (e.g. recorded offline).
  Future<ApiSession> logCompletedSession({
    required String techniqueRef,
    required int elapsedSec,
    int? targetDurationSec,
    int? cyclesCompleted,
    double? accuracyPct,
    DateTime? startedAt,
    DateTime? completedAt,
  }) async {
    final uid = await ensureUser();
    final data = _obj(await _request(
      'POST',
      '/api/users/${_seg(uid)}/sessions',
      body: {
        'technique': techniqueRef,
        'status': 'completed',
        'elapsed_sec': elapsedSec.clamp(0, maxSessionSec),
        if (targetDurationSec != null)
          'target_duration_sec': targetDurationSec.clamp(30, maxSessionSec),
        if (cyclesCompleted != null)
          'cycles_completed': cyclesCompleted.clamp(0, 10000),
        if (accuracyPct != null && accuracyPct.isFinite)
          'accuracy_pct': accuracyPct.clamp(0, 100),
        if (startedAt != null) 'started_at': _isoUtc(startedAt),
        if (completedAt != null) 'completed_at': _isoUtc(completedAt),
      },
    ));
    return ApiSession.fromJson(_obj(data['session']));
  }

  /// Saves progress on an in-progress session, or finishes it with
  /// status 'completed' or 'abandoned'. elapsedSec can never go backwards.
  Future<ApiSession> updateSession(
    String sessionId, {
    int? elapsedSec,
    int? cyclesCompleted,
    double? accuracyPct,
    String? status,
    DateTime? completedAt,
  }) async {
    final uid = await ensureUser();
    final data = _obj(await _request(
      'PATCH',
      '/api/users/${_seg(uid)}/sessions/${_seg(sessionId)}',
      body: {
        if (elapsedSec != null) 'elapsed_sec': elapsedSec.clamp(0, maxSessionSec),
        if (cyclesCompleted != null)
          'cycles_completed': cyclesCompleted.clamp(0, 10000),
        if (accuracyPct != null && accuracyPct.isFinite)
          'accuracy_pct': accuracyPct.clamp(0, 100),
        'status': ?status,
        if (completedAt != null) 'completed_at': _isoUtc(completedAt),
      },
    ));
    return ApiSession.fromJson(_obj(data['session']));
  }

  /// Saves what SessionPage returned. [previousElapsedSec] is the elapsed time
  /// the session already had, so a resumed session never goes backwards.
  Future<ApiSession> saveSessionResult(
    String sessionId,
    BreatheSessionResult result, {
    int previousElapsedSec = 0,
  }) {
    return updateSession(
      sessionId,
      elapsedSec: math.max(result.elapsedSec, previousElapsedSec),
      cyclesCompleted: result.cyclesCompleted,
      accuracyPct: result.accuracyPct,
      status: result.completed
          ? 'completed'
          : (result.abandoned ? 'abandoned' : null),
    );
  }

  /// Uploads a batch of BLE readings for an in-progress session.
  /// The backend accepts null detected_phase values; these are retained as
  /// sensor samples but excluded from phase-accuracy calculations.
  Future<Map<String, dynamic>> uploadBandReadings(
    String sessionId,
    List<Map<String, dynamic>> readings,
  ) async {
    if (readings.isEmpty) return const <String, dynamic>{};
    if (readings.length > 200) {
      throw const ApiException(-1, 'A readings batch cannot exceed 200 items.');
    }
    final uid = await ensureUser();
    final data = _obj(await _request(
      'POST',
      '/api/users/${_seg(uid)}/sessions/${_seg(sessionId)}/readings',
      body: {'readings': readings},
    ));
    return data;
  }

  /// Current server-side session accuracy and latest accepted BLE sample.
  Future<Map<String, dynamic>> getLiveSessionState(String sessionId) async {
    final uid = await ensureUser();
    return _obj(await _request(
      'GET',
      '/api/users/${_seg(uid)}/sessions/${_seg(sessionId)}/live',
    ));
  }

  /// History, newest first. [technique] is an id or slug.
  Future<ApiSessionHistory> listSessions({
    String? status,
    String? technique,
    int limit = 20,
    int offset = 0,
  }) async {
    final uid = await ensureUser();
    final data = _obj(await _request(
      'GET',
      '/api/users/${_seg(uid)}/sessions',
      query: {
        'limit': '${limit.clamp(1, 100)}',
        'offset': '${math.max(offset, 0)}',
        'status': ?status,
        'technique': ?technique,
      },
    ));
    return ApiSessionHistory(
      total: _int(data['total']),
      limit: _int(data['limit']),
      offset: _int(data['offset']),
      sessions:
          _objList(data['sessions']).map((j) => ApiSession.fromJson(j)).toList(),
    );
  }

  Future<ApiSession> getSession(String sessionId) async {
    final uid = await ensureUser();
    final data = _obj(await _request(
        'GET', '/api/users/${_seg(uid)}/sessions/${_seg(sessionId)}'));
    return ApiSession.fromJson(_obj(data['session']));
  }
}
