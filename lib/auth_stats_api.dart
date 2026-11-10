import 'dart:convert';

import 'auth_service.dart';
import 'stats_repository.dart';

/// Stats API that reuses AuthService (server address, tokens, auto-refresh).
class AuthStatsApi implements StatsApi {
  final _auth = AuthService.instance;

  Future<String> _id() async {
    final id = await _auth.userId;
    if (id == null) throw StatsApiException(401);
    return id;
  }

  @override
  Future<void> postVitals(List<Map<String, dynamic>> buckets) async {
    final id = await _id();
    final res = await _auth.authedPost('/api/users/$id/vitals', {'buckets': buckets});
    if (res.statusCode >= 300) throw StatsApiException(res.statusCode);
  }

  @override
  Future<Map<String, dynamic>> getStats(StatsPeriod period, int tzOffsetMin) async {
    final id = await _id();
    final res = await _auth.authedGet(
      '/api/users/$id/stats?period=${period.name}&tz_offset_min=$tzOffsetMin',
    );
    if (res.statusCode >= 300) throw StatsApiException(res.statusCode);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}