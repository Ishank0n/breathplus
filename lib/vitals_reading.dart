/// One reading sent by the ESP32 band.
///
/// The current firmware sends phase values: "inhale", "exhale", "hold",
/// "none" (no skin contact), or "unknown" (not yet detected).
class VitalsReading {
  final String phase;
  final double spo2;
  final double heartRate;
  final double hrv;
  final double stress;
  final int steps;
  final double wristTiltDeg;
  final String activity;
  final bool demo;
  final DateTime at;

  const VitalsReading({
    required this.phase,
    required this.spo2,
    required this.heartRate,
    required this.hrv,
    required this.stress,
    required this.steps,
    required this.wristTiltDeg,
    required this.activity,
    required this.demo,
    required this.at,
  });

  // Firmware sends JSON null until some sensor measurements are ready.
  // Unavailable values are represented as 0.0.
  static double _d(Object? value) => value is num ? value.toDouble() : 0.0;

  factory VitalsReading.fromJson(Map<String, dynamic> json) {
    final rawPhase = json['phase'];
    final rawActivity = json['activity'];

    return VitalsReading(
      phase: rawPhase is String ? rawPhase.toLowerCase() : 'unknown',
      spo2: _d(json['spo2_pct']),
      heartRate: _d(json['heart_rate_bpm']),
      hrv: _d(json['hrv_ms']),
      stress: _d(json['stress']),
      steps: json['steps'] is num ? (json['steps'] as num).toInt() : 0,
      wristTiltDeg: _d(json['wrist_tilt_deg']),
      activity: rawActivity is String ? rawActivity : 'stationary',
      demo: json['demo'] is bool ? json['demo'] as bool : false,
      at: DateTime.now(),
    );
  }
}