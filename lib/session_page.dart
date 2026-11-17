import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Re-uses AppColors, kSerif, Technique, PlantIcon and Pressable from main.dart
import 'main.dart';
import 'breathe_api.dart';
import 'audio_state.dart';
import 'audio_widgets.dart' show TrackTile, audioSnack;
import 'vitals_service.dart';
import 'vitals_reading.dart';

/// ---------------------------------------------------------------------------
/// PLACEHOLDER DATA  (replace with real data / state management)
/// ---------------------------------------------------------------------------
class SessionData {
  static const int accuracy = 87; // % (only used while no band is connected)
  static const int resumeElapsedSeconds = 108; // 03:12 left of a 5 min session
}

class _Phase {
  final String label; // Inhale
  final String action; // Inhaling
  final String hint;
  final int seconds;
  final String phaseKey; // inhale | hold_in | exhale | hold_out

  const _Phase(this.label, this.action, this.hint, this.seconds, this.phaseKey);
}

/// A flower available to use as the visual companion during a session.
class SessionFlower {
  final String id;
  final String name;
  final String emoji;

  const SessionFlower({
    required this.id,
    required this.name,
    required this.emoji,
  });
}

/// Builds the phases from a pattern string, e.g. "4-4-4-4", "4-7-8", "5-5".
List<_Phase> _phasesFor(String pattern) {
  final n = pattern.split('-').map((e) => int.tryParse(e) ?? 4).toList();

  _Phase inhale(int s) =>
      _Phase('Inhale', 'Inhaling', 'Breathe in slowly through your nose', s, 'inhale');
  _Phase hold(int s) =>
      _Phase('Hold', 'Holding', 'Hold your breath gently', s, 'hold');
  _Phase exhale(int s) =>
      _Phase('Exhale', 'Exhaling', 'Breathe out slowly through your mouth', s, 'exhale');

  if (n.length >= 4) return [inhale(n[0]), hold(n[1]), exhale(n[2]), hold(n[3])];
  if (n.length == 3) return [inhale(n[0]), hold(n[1]), exhale(n[2])];
  if (n.length == 2) return [inhale(n[0]), exhale(n[1])];
  return [inhale(4), exhale(4)];
}

/// ---------------------------------------------------------------------------
/// SESSION PAGE
/// ---------------------------------------------------------------------------
class SessionPage extends StatefulWidget {
  final Technique technique;
  final bool restart;

  const SessionPage({super.key, required this.technique, this.restart = false});

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage>
    with SingleTickerProviderStateMixin {
  late final List<_Phase> _phases;
  late final int _cycleSeconds;
  late final AnimationController _cycle;
  late final Duration _startOffset;
  final Stopwatch _sw = Stopwatch()..start();

  // Live data from the ESP32 band
  late final VitalsService _band;
  Timer? _uploadTimer;
  final Stopwatch _sessionStopwatch = Stopwatch()..start();
  final List<Map<String, dynamic>> _pendingReadings = [];
  DateTime? _lastReadingAt;
  int _lastElapsedMs = -1;
  bool _uploading = false;
  double _userTarget = _minScale; // circle size the user's breath is heading to
  int _accTotal = 0;
  int _accMatch = 0;

  AudioTrack? _sessionTrack;
  bool _done = false;

  // Garden flowers and the flower remembered for each breathing exercise.
  static const List<SessionFlower> _allFlowers = [
    SessionFlower(id: 'rose', name: 'Rose', emoji: '🌹'),
    SessionFlower(id: 'sunflower', name: 'Sunflower', emoji: '🌻'),
    SessionFlower(id: 'tulip', name: 'Tulip', emoji: '🌷'),
    SessionFlower(id: 'daisy', name: 'Daisy', emoji: '🌼'),
    SessionFlower(id: 'cherry', name: 'Cherry Blossom', emoji: '🌸'),
    SessionFlower(id: 'lavender', name: 'Lavender', emoji: '🪻'),
    SessionFlower(id: 'hibiscus', name: 'Hibiscus', emoji: '🌺'),
    SessionFlower(id: 'blossom', name: 'Blossom', emoji: '💮'),
    SessionFlower(id: 'lotus', name: 'Lotus', emoji: '🪷'),
  ];

  static const String _gardenKey = 'breathling_garden';
  static const String _exerciseFlowersKey = 'breathling_exercise_flowers';

  late SessionFlower _selectedFlower;
  List<SessionFlower> _gardenFlowers = [];
  bool _flowersLoading = true;

  String get _exerciseKey =>
      widget.technique.slug ??
      widget.technique.id?.toString() ??
      widget.technique.name;

  SessionFlower _defaultFlower() {
    // Stable rolling hash: the same exercise always gets the same starter flower.
    var hash = 0;
    for (final code in _exerciseKey.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return _allFlowers[hash % _allFlowers.length];
  }

  static const double _minScale = 0.82;

  @override
  void initState() {
    super.initState();
    _selectedFlower = _defaultFlower();
    _loadSessionFlower();
    _phases = widget.technique.phases.isNotEmpty
        ? widget.technique.phases.map((p) {
            final key = p.phase;
            final label = key == 'inhale'
                ? 'Inhale'
                : key == 'exhale'
                    ? 'Exhale'
                    : 'Hold';
            final action = key == 'inhale'
                ? 'Inhaling'
                : key == 'exhale'
                    ? 'Exhaling'
                    : 'Holding';
            final hint = key == 'inhale'
                ? 'Breathe in slowly through your nose'
                : key == 'exhale'
                    ? 'Breathe out slowly through your mouth'
                    : 'Hold your breath gently';
            return _Phase(label, action, hint, p.durationSec.round().clamp(1, 60).toInt(), key);
          }).toList()
        : _phasesFor(widget.technique.pattern);
    _cycleSeconds = _phases.fold(0, (a, p) => a + p.seconds);
    // Every newly opened exercise starts at its full default duration.
    // Do not carry elapsed time over from a previous session.
    _startOffset = Duration(seconds: widget.technique.elapsedSec);
    final cycleMs = math.max(1, _cycleSeconds * 1000);
    final initialCycleValue =
        (_startOffset.inMilliseconds % cycleMs) / cycleMs;
    _cycle = AnimationController(
      vsync: this,
      duration: Duration(seconds: _cycleSeconds),
      value: initialCycleValue,
    )..repeat();

    _band = context.read<VitalsService>();
    _band.addListener(_onBand);
    final p0 = _band.latest?.phase;
    if (p0 == 'inhale') _userTarget = 1.0;
    // Send BLE samples in small batches instead of making one HTTP request
    // for every 500 ms notification.
    _uploadTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _flushReadings(),
    );
  }

  @override
  void dispose() {
    _uploadTimer?.cancel();
    _band.removeListener(_onBand);
    _cycle.dispose();
    super.dispose();
  }

  /// Called for each BLE notification and connection-state change.
  void _onBand() {
    final reading = _band.latest;
    if (reading == null) return;

    final phase = reading.phase.toLowerCase();
    final target = phase == 'inhale'
        ? 1.0
        : phase == 'exhale'
            ? _minScale
            : null;

    // Count each actual BLE packet once. Generic `hold` is intentionally not
    // scored because the ESP32 cannot distinguish hold_in from hold_out.
    if (_lastReadingAt == null || reading.at.isAfter(_lastReadingAt!)) {
      _lastReadingAt = reading.at;
      final expected = _currentGuidePhaseKey();
      if (phase == 'inhale' || phase == 'exhale') {
        _accTotal++;
        if (phase == expected) _accMatch++;
      }
      _queueReading(reading);
    }

    if (!mounted) return;
    setState(() {
      if (target != null) _userTarget = target;
    });
  }

  String _currentGuidePhaseKey() {
    final cycleT = _cycle.value * _cycleSeconds;
    double elapsed = 0;
    for (final phase in _phases) {
      if (cycleT < elapsed + phase.seconds) return phase.phaseKey;
      elapsed += phase.seconds;
    }
    return _phases.last.phaseKey;
  }

  void _queueReading(VitalsReading reading) {
    final sessionId = widget.technique.sessionId;
    if (sessionId == null || !_band.isConnected) return;

    var elapsedMs = _startOffset.inMilliseconds +
        _sessionStopwatch.elapsedMilliseconds;
    if (elapsedMs <= _lastElapsedMs) elapsedMs = _lastElapsedMs + 1;
    _lastElapsedMs = elapsedMs;

    // Firmware currently sends phase from the two physical buttons. `hold`
    // has no inhale/exhale subtype, so send null and let the backend exclude
    // that sample from the accuracy denominator.
    final detected = (reading.phase == 'inhale' || reading.phase == 'exhale')
        ? reading.phase
        : null;

    final sensors = <String, dynamic>{};
    // The supplied firmware sets demo=true and generates mock vitals. Do not
    // persist those values as real health measurements.
    if (!reading.demo) {
      sensors.addAll({
        'spo2_pct': reading.spo2,
        'heart_rate_bpm': reading.heartRate,
        'hrv_ms': reading.hrv,
        'stress': reading.stress,
        'steps': reading.steps.toDouble(),
        'wrist_tilt_deg': reading.wristTiltDeg,
      });
    }

    _pendingReadings.add({
      'elapsed_ms': elapsedMs,
      'detected_phase': detected,
      'sensors': sensors,
    });
    if (_pendingReadings.length >= 10) _flushReadings();
  }

  Future<void> _flushReadings() async {
    final sessionId = widget.technique.sessionId;
    if (sessionId == null || _pendingReadings.isEmpty || _uploading) return;
    _uploading = true;
    final batch = _pendingReadings.take(40).toList();
    _pendingReadings.removeRange(0, batch.length);
    try {
      await BreatheApi.instance.uploadBandReadings(sessionId, batch);
    } catch (e) {
      // Keep failed readings for the next retry, preserving timestamp order.
      _pendingReadings.insertAll(0, batch);
      if (_pendingReadings.length > 200) {
        _pendingReadings.removeRange(0, _pendingReadings.length - 200);
      }
      debugPrint('Could not upload band readings: $e');
    } finally {
      _uploading = false;
    }
  }

  Future<void> _finishSession({required bool completed}) async {
    if (_done) return;
    _done = true;
    _uploadTimer?.cancel();
    // Give any in-flight upload a chance to finish, then send the final batch.
    while (_uploading) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await _flushReadings();
    if (!mounted) return;
    final elapsed = _startOffset.inSeconds + _sessionStopwatch.elapsed.inSeconds;
    final accuracy = _accTotal == 0 ? null : (_accMatch / _accTotal) * 100;
    Navigator.of(context).pop(BreatheSessionResult(
      elapsedSec: elapsed,
      cyclesCompleted: _cycleSeconds <= 0 ? 0 : elapsed ~/ _cycleSeconds,
      accuracyPct: accuracy,
      completed: completed,
      abandoned: !completed,
    ));
  }

  String _fmt(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _actionFor(String? bandPhase) {
    switch (bandPhase) {
      case 'inhale':
        return 'Inhaling';
      case 'exhale':
        return 'Exhaling';
      default:
        return 'Holding';
    }
  }

  /// Loads flowers planted in the Garden and this exercise's saved selection.
  Future<void> _loadSessionFlower() async {
    final prefs = await SharedPreferences.getInstance();
    final savedGarden = prefs.getString(_gardenKey);
    final savedChoices = prefs.getString(_exerciseFlowersKey);

    final garden = <SessionFlower>[];
    if (savedGarden != null) {
      try {
        final Map<String, dynamic> data = jsonDecode(savedGarden);
        for (final id in data.values) {
          final matches = _allFlowers.where((flower) => flower.id == id);
          if (matches.isNotEmpty &&
              !garden.any((flower) => flower.id == matches.first.id)) {
            garden.add(matches.first);
          }
        }
      } catch (e) {
        debugPrint('Could not read garden flowers: $e');
      }
    }

    var selected = _defaultFlower();
    if (savedChoices != null) {
      try {
        final Map<String, dynamic> choices = jsonDecode(savedChoices);
        final savedId = choices[_exerciseKey];
        final matches = _allFlowers.where((flower) => flower.id == savedId);
        if (matches.isNotEmpty) selected = matches.first;
      } catch (e) {
        debugPrint('Could not read saved exercise flowers: $e');
      }
    }

    if (!mounted) return;
    setState(() {
      _gardenFlowers = garden;
      _selectedFlower = selected;
      _flowersLoading = false;
    });
  }

  Future<void> _saveExerciseFlower(SessionFlower flower) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_exerciseFlowersKey);
    Map<String, dynamic> choices = {};

    if (raw != null) {
      try {
        choices = Map<String, dynamic>.from(jsonDecode(raw));
      } catch (_) {
        choices = {};
      }
    }

    choices[_exerciseKey] = flower.id;
    await prefs.setString(_exerciseFlowersKey, jsonEncode(choices));
  }

  void _openFlowerPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
          decoration: const BoxDecoration(
            color: AppColors.bgTop,
            borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
            border: Border(top: BorderSide(color: AppColors.cardBorder, width: 1.2)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.cardBorder,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Choose your flower',
                  style: TextStyle(
                    fontFamily: kSerif,
                    fontFamilyFallback: kSerifFallback,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    color: AppColors.white,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'Select a flower you have planted in your Garden.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.mintText, fontSize: 13),
                ),
                const SizedBox(height: 22),
                if (_flowersLoading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: CircularProgressIndicator(color: AppColors.mint),
                  )
                else if (_gardenFlowers.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: [
                        Icon(Icons.local_florist_outlined, size: 45, color: AppColors.mint),
                        SizedBox(height: 12),
                        Text(
                          'Your garden is empty!',
                          style: TextStyle(color: AppColors.white, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Plant some flowers in your Garden first.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.mintText, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _gardenFlowers.length,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.05,
                    ),
                    itemBuilder: (context, index) {
                      final flower = _gardenFlowers[index];
                      final selected = flower.id == _selectedFlower.id;
                      return GestureDetector(
                        onTap: () {
                          setState(() => _selectedFlower = flower);
                          _saveExerciseFlower(flower);
                          Navigator.pop(sheetContext);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            color: selected ? const Color(0xFF315B40) : AppColors.card,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: selected ? AppColors.mint : AppColors.cardBorder,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(flower.emoji, style: const TextStyle(fontSize: 34)),
                              const SizedBox(height: 6),
                              Text(
                                flower.name,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFlowerSelectorCard() {
    return _SessionCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          Text(_selectedFlower.emoji, style: const TextStyle(fontSize: 32)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your companion flower',
                  style: TextStyle(color: AppColors.mintText, fontSize: 11.5),
                ),
                const SizedBox(height: 3),
                Text(
                  _selectedFlower.name,
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Pressable(
            onTap: _openFlowerPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
              decoration: BoxDecoration(color: AppColors.mint, borderRadius: BorderRadius.circular(20)),
              child: const Text(
                'Change',
                style: TextStyle(color: AppColors.dark, fontSize: 12, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMusicPicker() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final height = MediaQuery.of(sheetContext).size.height * 0.78;
        return SafeArea(
          top: false,
          child: Container(
            height: height,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
            decoration: const BoxDecoration(
              color: AppColors.bgTop,
              borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
              border: Border(top: BorderSide(color: AppColors.cardBorder, width: 1.2)),
            ),
            child: AnimatedBuilder(
              animation: audio,
              builder: (context, _) {
                final presets = audio.library;
                final imported = audio.imported;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.cardBorder,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Choose your music',
                      style: TextStyle(
                        fontFamily: kSerif,
                        fontFamilyFallback: kSerifFallback,
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        color: AppColors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Pick a preset sound or use audio from your device.',
                      style: TextStyle(color: AppColors.mintText, fontSize: 12.5),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Preset sounds',
                            style: TextStyle(color: AppColors.white, fontSize: 14, fontWeight: FontWeight.w800),
                          ),
                        ),
                        Text(
                          '${presets.length} available',
                          style: const TextStyle(color: AppColors.mintText, fontSize: 11.5),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: ListView(
                        physics: const BouncingScrollPhysics(),
                        children: [
                          for (final track in presets)
                            TrackTile(
                              key: ValueKey('session-${track.id}'),
                              track: track,
                              isCurrent: _sessionTrack?.id == track.id,
                              isPlaying: _sessionTrack?.id == track.id && audio.isPlaying,
                              onTap: () {
                                setState(() => _sessionTrack = track);
                                if (audio.current?.id != track.id || !audio.isPlaying) {
                                  audio.toggle(track);
                                }
                                Navigator.of(sheetContext).pop();
                              },
                            ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Your imported music',
                                  style: TextStyle(color: AppColors.white, fontSize: 14, fontWeight: FontWeight.w800),
                                ),
                              ),
                              Pressable(
                                onTap: audio.importing
                                    ? () {}
                                    : () async {
                                        final result = await audio.importAudio();
                                        if (!mounted) return;
                                        String message;
                                        if (result.error != null) {
                                          message = result.error!;
                                        } else if (result.cancelled) {
                                          return;
                                        } else if (result.added == 0) {
                                          message = 'Those tracks are already imported';
                                        } else {
                                          message = 'Imported ${result.added} ${result.added == 1 ? 'track' : 'tracks'}. Select one below.';
                                        }
                                        audioSnack(ScaffoldMessenger.of(context), message);
                                      },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(color: AppColors.cardBorder),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (audio.importing)
                                        const SizedBox(
                                          width: 13,
                                          height: 13,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mint),
                                        )
                                      else
                                        const Icon(Icons.add_rounded, size: 16, color: AppColors.mint),
                                      const SizedBox(width: 5),
                                      Text(
                                        audio.importing ? 'Importing' : 'Import',
                                        style: const TextStyle(color: AppColors.mint, fontSize: 12, fontWeight: FontWeight.w700),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          if (imported.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 18),
                              child: Text(
                                'Your imported tracks will appear here.',
                                style: TextStyle(color: AppColors.mintText, fontSize: 12),
                              ),
                            )
                          else
                            for (final track in imported)
                              TrackTile(
                                key: ValueKey('session-${track.id}'),
                                track: track,
                                isCurrent: _sessionTrack?.id == track.id,
                                isPlaying: _sessionTrack?.id == track.id && audio.isPlaying,
                                onTap: () {
                                  setState(() => _sessionTrack = track);
                                  if (audio.current?.id != track.id || !audio.isPlaying) {
                                    audio.toggle(track);
                                  }
                                  Navigator.of(sheetContext).pop();
                                },
                              ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildMusicCard() {
    return AnimatedBuilder(
      animation: audio,
      builder: (context, _) {
        final track = _sessionTrack;
        final playing = track != null && audio.current?.id == track.id && audio.isPlaying;
        return _SessionCard(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(color: Color(0xFF23503F), shape: BoxShape.circle),
                child: const Icon(Icons.music_note_rounded, color: AppColors.mint, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Session music', style: TextStyle(color: AppColors.mintText, fontSize: 11.5)),
                    const SizedBox(height: 3),
                    Text(
                      track?.title ?? 'Choose a sound for your session',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.white, fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    if (track != null)
                      Text(playing ? 'Playing' : 'Paused', style: const TextStyle(color: AppColors.mintText, fontSize: 11)),
                  ],
                ),
              ),
              if (track != null)
                Pressable(
                  onTap: () => audio.toggle(track),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: AppColors.mint, size: 23),
                  ),
                ),
              Pressable(
                onTap: _openMusicPicker,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                  decoration: BoxDecoration(color: AppColors.mint, borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    track == null ? 'Choose' : 'Change',
                    style: const TextStyle(color: AppColors.dark, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.technique;

    return Scaffold(
      backgroundColor: AppColors.bgBottom,
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBottom],
          ),
        ),
        child: SafeArea(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeOutCubic,
            builder: (context, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(
                offset: Offset(0, 16 * (1 - v)),
                child: child,
              ),
            ),
            child: AnimatedBuilder(
              animation: _cycle,
              builder: (context, _) => _buildContent(t),
            ),
          ),
        ),
      ),
    );
  }

  Widget _circle(double s) {
    return Transform.scale(
      scale: s,
      child: Container(
        width: 206,
        height: 206,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF1F4A3A),
          border: Border.all(
            color: const Color(0xFF7FD69A),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.mint.withAlpha(
                  (20 + 50 * (s - _minScale) / (1 - _minScale))
                      .round()
                      .clamp(0, 255)
                      .toInt()),
              blurRadius: 28,
              spreadRadius: 2,
            ),
          ],
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Text(
            _selectedFlower.emoji,
            key: ValueKey(_selectedFlower.id),
            style: const TextStyle(fontSize: 82),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(Technique t) {
    // ---- Timing -----------------------------------------------------------
    final totalSession = t.minutes * 60;
    final elapsedSession = (_sw.elapsed + _startOffset).inSeconds;
    final remaining = math.max(0, totalSession - elapsedSession);

    if (remaining <= 0 && !_done) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finishSession(completed: true);
      });
    }

    final cycleT = _cycle.value * _cycleSeconds;
    double acc = 0;
    int idx = 0;
    for (int i = 0; i < _phases.length; i++) {
      if (cycleT < acc + _phases[i].seconds || i == _phases.length - 1) {
        idx = i;
        break;
      }
      acc += _phases[i].seconds;
    }
    final phase = _phases[idx];
    final inPhase = (cycleT - acc).clamp(0.0, phase.seconds.toDouble());
    final phaseProgress = inPhase / phase.seconds;
    final secondsLeft = (phase.seconds - inPhase).ceil().clamp(0, phase.seconds);

    // ---- Guide circle scale -------------------------------------------------
    double scale;
    final eased = Curves.easeInOut.transform(phaseProgress);
    if (phase.label == 'Inhale') {
      scale = _minScale + (1 - _minScale) * eased;
    } else if (phase.label == 'Exhale') {
      scale = 1 - (1 - _minScale) * eased;
    } else {
      final prev = _phases[(idx - 1 + _phases.length) % _phases.length];
      scale = prev.label == 'Inhale' ? 1.0 : _minScale;
    }

    // Breath bar: fills while inhaling, stays full through the hold, drains
    // while exhaling (and stays empty through a hold after the exhale).
    final breathLevel = ((scale - _minScale) / (1 - _minScale))
        .clamp(0.0, 1.0)
        .toDouble();

    // ---- Live band data -------------------------------------------------------
    final live = _band.isLive;
    final bandPhase = _band.latest?.phase;
    final inSync = live && (bandPhase == phase.phaseKey || (bandPhase == 'hold' && phase.phaseKey.startsWith('hold_')));
    final accuracy = live
        ? (_accTotal == 0 ? 0.0 : _accMatch / _accTotal)
        : SessionData.accuracy / 100;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: Column(
        children: [
          // ---- Top bar ----------------------------------------------------
          Row(
            children: [
              Pressable(
                onTap: () => _finishSession(completed: false),
                child: Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x661F4A3A),
                    border: Border.all(color: AppColors.cardBorder, width: 1.3),
                  ),
                  child: const Text(
                    'X',
                    style: TextStyle(
                      color: AppColors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    t.name,
                    style: const TextStyle(
                      fontFamily: kSerif,
                      fontFamilyFallback: kSerifFallback,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppColors.white,
                    ),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
                decoration: BoxDecoration(
                  color: const Color(0xFF23503F),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_fmt(remaining)} left',
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // ---- Breathing circle -------------------------------------------
          // Band connected: the circle follows YOUR breathing (inhale grows,
          // exhale shrinks) and a thin ring shows the guide's target size.
          // No band: the circle simply follows the guide.
          SizedBox(
            height: 212,
            width: 212,
            child: Center(
              child: live
                  ? Stack(
                      alignment: Alignment.center,
                      children: [
                        Transform.scale(
                          scale: scale,
                          child: Container(
                            width: 206,
                            height: 206,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.amber.withAlpha(150),
                                width: 1.5,
                              ),
                            ),
                          ),
                        ),
                        TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: _minScale, end: _userTarget),
                          duration: const Duration(milliseconds: 1400),
                          curve: Curves.easeInOut,
                          builder: (context, s, _) => _circle(s),
                        ),
                      ],
                    )
                  : _circle(scale),
            ),
          ),
          const SizedBox(height: 14),

          // The user can change the flower companion without leaving the session.
          _buildFlowerSelectorCard(),

          const SizedBox(height: 18),

          // ---- Phase text ---------------------------------------------------
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1).animate(anim),
                child: child,
              ),
            ),
            child: Text(
              phase.label,
              key: ValueKey('${phase.label}$idx'),
              style: const TextStyle(
                fontFamily: kSerif,
                fontFamilyFallback: kSerifFallback,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                color: AppColors.white,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            phase.hint,
            style: const TextStyle(color: AppColors.mintText, fontSize: 13.5),
          ),
          const SizedBox(height: 12),

          // ---- Phase progress ---------------------------------------------
          Row(
            children: [
              Text(
                '${secondsLeft}s left',
                style: const TextStyle(color: AppColors.mintText, fontSize: 12),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: breathLevel,
                    minHeight: 8,
                    backgroundColor: const Color(0xFF2E6B52),
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppColors.mint),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${phase.seconds}s',
                style: const TextStyle(color: AppColors.mintText, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ---- Band vitals --------------------------------------------------
          _buildBandCard(),
          const SizedBox(height: 14),

          // ---- Status + accuracy cards ------------------------------------
          SizedBox(
            height: 124,
            child: Row(
              children: [
                Expanded(
                  flex: 11,
                  child: _SessionCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'You are',
                          style: TextStyle(
                              color: AppColors.mintText, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          child: Text(
                            live ? _actionFor(bandPhase) : phase.action,
                            key: ValueKey(live
                                ? 'band-$bandPhase'
                                : phase.action + idx.toString()),
                            style: const TextStyle(
                              fontFamily: kSerif,
                              fontFamilyFallback: kSerifFallback,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: AppColors.white,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          !live
                              ? 'Connect your band to track'
                              : inSync
                                  ? 'In sync with the guide'
                                  : 'Follow the guide: ${phase.label.toLowerCase()}',
                          style: TextStyle(
                            color: live && !inSync
                                ? AppColors.amber
                                : AppColors.mintText,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 8,
                  child: _SessionCard(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0, end: accuracy),
                          duration: const Duration(milliseconds: 1200),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, _) => SizedBox(
                            width: 74,
                            height: 74,
                            child: CustomPaint(
                              painter: _RingPainter(value),
                              child: Center(
                                child: Text(
                                  '${(value * 100).round()}%',
                                  style: const TextStyle(
                                    fontFamily: kSerif,
                                    fontFamilyFallback: kSerifFallback,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Accuracy',
                          style: TextStyle(
                              color: AppColors.mintText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ---- Session music ------------------------------------------------
          _buildMusicCard(),
        ],
      ),
    );
  }

  /// Live heart rate / SpO2 / HRV, or a "connect your band" prompt.
  Widget _buildBandCard() {
    final r = _band.latest;
    if (_band.isLive && r != null) {
      return _SessionCard(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _MiniStat(value: '${r.heartRate.round()} bpm', label: 'Heart rate'),
            _MiniStat(value: '${r.spo2.round()}%', label: 'Oxygen'),
            _MiniStat(value: '${r.hrv.round()} ms', label: 'HRV'),
          ],
        ),
      );
    }

    final busy = _band.isBusy;
    final text = _band.status == BandStatus.scanning
        ? 'Searching for band…'
        : _band.status == BandStatus.connecting
            ? 'Connecting to band…'
            : _band.isConnected
                ? 'Waiting for data…'
                : (_band.error ?? 'Band not connected');

    return _SessionCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_searching_rounded,
              size: 18, color: AppColors.mintText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.mintText, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.mint),
            )
          else if (!_band.isConnected)
            Pressable(
              pressedScale: 0.92,
              onTap: _band.connectToBand,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.mint,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  'Connect',
                  style: TextStyle(
                    color: AppColors.dark,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// WIDGETS
/// ---------------------------------------------------------------------------
class _MiniStat extends StatelessWidget {
  final String value;
  final String label;

  const _MiniStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontFamily: kSerif,
            fontFamilyFallback: kSerifFallback,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppColors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: AppColors.mintText, fontSize: 11.5),
        ),
      ],
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _SessionCard({required this.child, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0x661F4A3A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xAA2E6B52), width: 1.2),
      ),
      child: child,
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value; // 0..1

  _RingPainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final rect = Offset.zero & size;
    final r = Rect.fromLTWH(
      rect.left + stroke / 2,
      rect.top + stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFF2E6B52);
    canvas.drawArc(r, 0, math.pi * 2, false, track);

    final prog = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke
      ..color = AppColors.mint;
    canvas.drawArc(r, -math.pi / 2, math.pi * 2 * value, false, prog);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.value != value;
}