/// One reading sent by the ESP32 band, e.g.
/// {"phase":"exhale","spo2_pct":98.8,"heart_rate_bpm":86.7,"hrv_ms":80.0,
///  "stress":19.3,"steps":2269,"wrist_tilt_deg":-30.2,
///  "activity":"stationary","demo":true}
class VitalsReading {
  /// "inhale", "exhale" or "hold" (driven by the two buttons on the ESP32).
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

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;

  factory VitalsReading.fromJson(Map<String, dynamic> j) => VitalsReading(
        phase: (j['phase'] as String?) ?? 'hold',
        spo2: _d(j['spo2_pct']),
        heartRate: _d(j['heart_rate_bpm']),
        hrv: _d(j['hrv_ms']),
        stress: _d(j['stress']),
        steps: (j['steps'] as num?)?.toInt() ?? 0,
        wristTiltDeg: _d(j['wrist_tilt_deg']),
        activity: (j['activity'] as String?) ?? 'stationary',
        demo: (j['demo'] as bool?) ?? false,
        at: DateTime.now(),
      );
}