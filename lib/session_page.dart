import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Re-uses AppColors, kSerif, Technique, PlantIcon and Pressable from main.dart
import 'main.dart';
import 'audio_widgets.dart' show SeekBar;
import 'vitals_service.dart';

/// ---------------------------------------------------------------------------
/// PLACEHOLDER DATA  (replace with real data / state management)
/// ---------------------------------------------------------------------------
class SessionData {
  static const int accuracy = 87; // % (only used while no band is connected)
  static const String nowPlaying = 'Rain on Leaves';
  static const double audioProgress = 0.59; // 0..1
  static const String plantName = 'Fern';
  static const int resumeElapsedSeconds = 108; // 03:12 left of a 5 min session
}

class _Phase {
  final String label; // Inhale
  final String action; // Inhaling
  final String hint;
  final int seconds;

  const _Phase(this.label, this.action, this.hint, this.seconds);
}

/// Builds the phases from a pattern string, e.g. "4-4-4-4", "4-7-8", "5-5".
List<_Phase> _phasesFor(String pattern) {
  final n = pattern.split('-').map((e) => int.tryParse(e) ?? 4).toList();

  _Phase inhale(int s) =>
      _Phase('Inhale', 'Inhaling', 'Breathe in slowly through your nose', s);
  _Phase hold(int s) =>
      _Phase('Hold', 'Holding', 'Hold your breath gently', s);
  _Phase exhale(int s) =>
      _Phase('Exhale', 'Exhaling', 'Breathe out slowly through your mouth', s);

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
  Timer? _accTimer;
  double _userTarget = _minScale; // circle size the user's breath is heading to
  int _accTotal = 0;
  int _accMatch = 0;

  double _audio = SessionData.audioProgress;
  bool _done = false;

  static const double _minScale = 0.82;

  @override
  void initState() {
    super.initState();
    _phases = _phasesFor(widget.technique.pattern);
    _cycleSeconds = _phases.fold(0, (a, p) => a + p.seconds);
    _startOffset = widget.restart
        ? Duration.zero
        : const Duration(seconds: SessionData.resumeElapsedSeconds);
    _cycle = AnimationController(
      vsync: this,
      duration: Duration(seconds: _cycleSeconds),
    )..repeat();

    _band = context.read<VitalsService>();
    _band.addListener(_onBand);
    final p0 = _band.latest?.phase;
    if (p0 == 'inhale') _userTarget = 1.0;
    _accTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _sampleAccuracy(),
    );
  }

  @override
  void dispose() {
    _accTimer?.cancel();
    _band.removeListener(_onBand);
    _cycle.dispose();
    super.dispose();
  }

  /// Called whenever the band sends data or its connection changes.
  void _onBand() {
    final p = _band.latest?.phase;
    // Inhale = circle grows, exhale = circle shrinks, hold = stays as it is.
    final target = p == 'inhale'
        ? 1.0
        : p == 'exhale'
            ? _minScale
            : null;
    if (!mounted) return;
    setState(() {
      if (target != null) _userTarget = target;
    });
  }

  /// Every half second, check whether the user's breathing phase matches the
  /// guide's phase. The accuracy ring is the share of matching samples.
  void _sampleAccuracy() {
    if (!_band.isLive) return;
    final cycleT = _cycle.value * _cycleSeconds;
    double acc = 0;
    String label = _phases.last.label;
    for (final p in _phases) {
      if (cycleT < acc + p.seconds) {
        label = p.label;
        break;
      }
      acc += p.seconds;
    }
    _accTotal++;
    if (_band.latest!.phase == label.toLowerCase()) _accMatch++;
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

  Widget _circle(Technique t, double s) {
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
        child: PlantIcon(type: t.plant, size: 136),
      ),
    );
  }

  Widget _buildContent(Technique t) {
    // ---- Timing -----------------------------------------------------------
    final totalSession = t.minutes * 60;
    final elapsedSession = (_sw.elapsed + _startOffset).inSeconds;
    final remaining = math.max(0, totalSession - elapsedSession);

    if (remaining <= 0 && !_done) {
      _done = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
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
    final inSync = live && bandPhase == phase.label.toLowerCase();
    final accuracy = live
        ? (_accTotal == 0 ? 0.0 : _accMatch / _accTotal)
        : SessionData.accuracy / 100;

    final done = (t.progress).clamp(0, t.goal);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: Column(
        children: [
          // ---- Top bar ----------------------------------------------------
          Row(
            children: [
              Pressable(
                onTap: () => Navigator.of(context).maybePop(),
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
                          builder: (context, s, _) => _circle(t, s),
                        ),
                      ],
                    )
                  : _circle(t, scale),
            ),
          ),
          const SizedBox(height: 8),

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

          // ---- Now playing ------------------------------------------------
          _SessionCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Now playing',
                  style: TextStyle(color: AppColors.mintText, fontSize: 12),
                ),
                const SizedBox(height: 3),
                const Text(
                  SessionData.nowPlaying,
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SeekBar(
                  value: _audio,
                  onChanged: (v) => setState(() => _audio = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ---- Footer -------------------------------------------------------
          Text(
            '${SessionData.plantName} · $done/${t.goal} successful sessions '
            'to grow. Finish a first session to collect it.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.mintText,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(t.goal, (i) {
              final filled = i < done;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 14,
                height: 14,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? AppColors.mint : const Color(0xFF2E6B52),
                ),
              );
            }),
          ),
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