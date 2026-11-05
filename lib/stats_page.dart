import 'dart:math' as math;

import 'package:flutter/material.dart';

// Re-uses Pressable, kSerif and kSerifFallback from main.dart
import 'main.dart';

/// ---------------------------------------------------------------------------
/// THEME (Statistics uses a teal palette)
/// ---------------------------------------------------------------------------
class StatsColors {
  static const bgTop = Color(0xFF14292F);
  static const bgBottom = Color(0xFF0E1E23);
  static const card = Color(0xFF1B363E);
  static const cardBorder = Color(0xFF2D5159);
  static const mint = Color(0xFF7FE3C5);
  static const bar = Color(0xFF2B4D55);
  static const white = Color(0xFFF1F7F5);
  static const muted = Color(0xFFA9C7C1);
  static const label = Color(0xFF7FC4B4);
  static const navBg = Color(0xFF17323A);
  static const navBorder = Color(0x662D5159);
}

/// ---------------------------------------------------------------------------
/// PLACEHOLDER DATA  (replace with real data / state management)
/// ---------------------------------------------------------------------------
enum StatsPeriod { day, week, month, year }

extension StatsPeriodX on StatsPeriod {
  String get label {
    switch (this) {
      case StatsPeriod.day:
        return 'Day';
      case StatsPeriod.week:
        return 'Week';
      case StatsPeriod.month:
        return 'Month';
      case StatsPeriod.year:
        return 'Year';
    }
  }
}

/// Maps raw values to 0..1 for a line chart between [lo] and [hi].
List<double> _line(List<double> v, double lo, double hi) =>
    v.map((e) => ((e - lo) / (hi - lo)).clamp(0.0, 1.0).toDouble()).toList();

/// Maps raw values to 0..1 relative to the biggest value.
List<double> _bars(List<double> v) {
  final m = v.reduce(math.max);
  return v.map((e) => (e / m).clamp(0.0, 1.0).toDouble()).toList();
}

class PeriodStats {
  // Header labels
  final String heartRate;
  final String oxygen;
  final String steps;
  final String calories;

  // Breathing tiles
  final String collectibles;
  final String exercises;
  final String totalTime;

  // Chart data (normalised 0..1). Lines have 8 points, bars have 7.
  final List<double> heartLine;
  final List<double> oxygenLine;
  final List<double> stepsBars;
  final List<double> caloriesBars;

  const PeriodStats({
    required this.heartRate,
    required this.oxygen,
    required this.steps,
    required this.calories,
    required this.collectibles,
    required this.exercises,
    required this.totalTime,
    required this.heartLine,
    required this.oxygenLine,
    required this.stepsBars,
    required this.caloriesBars,
  });

  _Series get series => _Series(heartLine, oxygenLine, stepsBars, caloriesBars);
}

class StatsData {
  static final Map<StatsPeriod, PeriodStats> data = {
    StatsPeriod.day: PeriodStats(
      heartRate: '68 bpm',
      oxygen: '98%',
      steps: '6,420',
      calories: '1,840 kcal',
      collectibles: '1',
      exercises: '6',
      totalTime: '28m',
      heartLine: _line([64, 62, 70, 78, 82, 76, 72, 70], 50, 100),
      oxygenLine: _line([97.8, 98, 97.6, 98.2, 98, 97.9, 98.1, 98], 96, 100),
      stepsBars: _bars([420, 980, 760, 1500, 640, 1100, 1020]),
      caloriesBars: _bars([160, 240, 280, 390, 230, 300, 240]),
    ),
    StatsPeriod.week: PeriodStats(
      heartRate: '72 bpm',
      oxygen: '98%',
      steps: '6,420',
      calories: '1,840 kcal',
      collectibles: '5',
      exercises: '42',
      totalTime: '3h 20m',
      heartLine: _line([70, 76, 66, 84, 72, 78, 62, 74], 50, 100),
      oxygenLine: _line([97.5, 98, 97.8, 98.2, 97.9, 98.4, 98.1, 98], 96, 100),
      stepsBars: _bars([3200, 4800, 3900, 6000, 5200, 2600, 6420]),
      caloriesBars: _bars([1300, 1250, 1500, 1400, 1700, 1200, 1840]),
    ),
    StatsPeriod.month: PeriodStats(
      heartRate: '71 bpm',
      oxygen: '97%',
      steps: '5,980',
      calories: '1,720 kcal',
      collectibles: '12',
      exercises: '168',
      totalTime: '13h 10m',
      heartLine: _line([68, 72, 70, 75, 69, 73, 71, 72], 50, 100),
      oxygenLine: _line([97, 97.4, 97.2, 97.8, 97.5, 97.1, 97.6, 97], 96, 100),
      stepsBars: _bars([5200, 6100, 4800, 6900, 5600, 6400, 5980]),
      caloriesBars: _bars([1600, 1700, 1550, 1850, 1700, 1800, 1720]),
    ),
    StatsPeriod.year: PeriodStats(
      heartRate: '70 bpm',
      oxygen: '97%',
      steps: '5,640',
      calories: '1,690 kcal',
      collectibles: '41',
      exercises: '1,920',
      totalTime: '152h 30m',
      heartLine: _line([73, 71, 69, 70, 68, 70, 71, 70], 50, 100),
      oxygenLine: _line([97.2, 97.5, 97.1, 97.4, 97.6, 97.3, 97.5, 97.4], 96, 100),
      stepsBars: _bars([4800, 5200, 6000, 6400, 5900, 5100, 5640]),
      caloriesBars: _bars([1550, 1600, 1750, 1800, 1700, 1620, 1690]),
    ),
  };
}

/// Chart values currently on screen (lets us animate between periods).
class _Series {
  final List<double> heart;
  final List<double> oxygen;
  final List<double> steps;
  final List<double> calories;

  const _Series(this.heart, this.oxygen, this.steps, this.calories);

  factory _Series.flat() => _Series(
        List.filled(8, 0.0),
        List.filled(8, 0.0),
        List.filled(7, 0.0),
        List.filled(7, 0.0),
      );

  static List<double> _l(List<double> a, List<double> b, double t) =>
      List.generate(b.length, (i) => a[i] + (b[i] - a[i]) * t);

  static _Series lerp(_Series a, _Series b, double t) => _Series(
        _l(a.heart, b.heart, t),
        _l(a.oxygen, b.oxygen, t),
        _l(a.steps, b.steps, t),
        _l(a.calories, b.calories, t),
      );
}

/// ---------------------------------------------------------------------------
/// STATS PAGE
/// ---------------------------------------------------------------------------
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> with TickerProviderStateMixin {
  StatsPeriod _period = StatsPeriod.week;

  late final AnimationController _intro;
  late final AnimationController _morph;
  late _Series _from;
  late _Series _to;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..forward();
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _from = _Series.flat();
    _to = StatsData.data[_period]!.series;

    // Charts grow in just after the cards fade in.
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _morph.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    _morph.dispose();
    super.dispose();
  }

  _Series get _shown => _Series.lerp(
        _from,
        _to,
        Curves.easeOutCubic.transform(_morph.value),
      );

  void _select(StatsPeriod p) {
    if (p == _period) return;
    final current = _shown; // snapshot so interrupted animations stay smooth
    setState(() {
      _from = current;
      _to = StatsData.data[p]!.series;
      _period = p;
    });
    _morph.forward(from: 0);
  }

  Widget _stagger(int index, Widget child) {
    final begin = (index * 0.09).clamp(0.0, 0.6).toDouble();
    final end = (begin + 0.4).clamp(0.0, 1.0).toDouble();
    final anim = CurvedAnimation(
      parent: _intro,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: anim,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.1),
          end: Offset.zero,
        ).animate(anim),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = StatsData.data[_period]!;

    return SafeArea(
      bottom: false,
      child: AnimatedBuilder(
        animation: _morph,
        builder: (context, _) {
          final s = _shown;
          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _stagger(
                  0,
                  const Text(
                    'Statistics',
                    style: TextStyle(
                      fontFamily: kSerif,
                      fontFamilyFallback: kSerifFallback,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: StatsColors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _stagger(
                  1,
                  _PeriodSelector(selected: _period, onChanged: _select),
                ),
                const SizedBox(height: 14),
                _stagger(
                  2,
                  _StatCard(
                    title: 'Heart rate',
                    value: stats.heartRate,
                    child: SizedBox(
                      height: 46,
                      width: double.infinity,
                      child: CustomPaint(painter: _LinePainter(s.heart)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _stagger(
                  3,
                  _StatCard(
                    title: 'Blood oxygen',
                    value: stats.oxygen,
                    child: SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: CustomPaint(painter: _LinePainter(s.oxygen)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _stagger(
                  4,
                  _StatCard(
                    title: 'Steps',
                    value: stats.steps,
                    child: SizedBox(
                      height: 62,
                      width: double.infinity,
                      child: CustomPaint(painter: _BarsPainter(s.steps)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _stagger(
                  5,
                  _StatCard(
                    title: 'Calories burnt',
                    value: stats.calories,
                    child: SizedBox(
                      height: 62,
                      width: double.infinity,
                      child: CustomPaint(painter: _BarsPainter(s.calories)),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _stagger(
                  6,
                  const Text(
                    'Breathing',
                    style: TextStyle(color: StatsColors.muted, fontSize: 12.5),
                  ),
                ),
                const SizedBox(height: 10),
                _stagger(
                  7,
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _MiniTile(
                            value: stats.collectibles,
                            label: 'Collectibles',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MiniTile(
                            value: stats.exercises,
                            label: 'Exercises done',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MiniTile(
                            value: stats.totalTime,
                            label: 'Total time',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// WIDGETS
/// ---------------------------------------------------------------------------
class _PeriodSelector extends StatelessWidget {
  final StatsPeriod selected;
  final ValueChanged<StatsPeriod> onChanged;

  const _PeriodSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final count = StatsPeriod.values.length;
    final idx = selected.index;

    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: StatsColors.card,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: StatsColors.cardBorder, width: 1.2),
      ),
      child: Stack(
        children: [
          // Sliding mint pill
          AnimatedAlign(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            alignment: Alignment(-1 + 2 * idx / (count - 1), 0),
            child: FractionallySizedBox(
              widthFactor: 1 / count,
              heightFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: StatsColors.mint,
                  borderRadius: BorderRadius.circular(22),
                ),
              ),
            ),
          ),
          // Labels
          Positioned.fill(
            child: Row(
              children: StatsPeriod.values.map((p) {
                final isSel = p == selected;
                return Expanded(
                  child: Pressable(
                    pressedScale: 0.94,
                    onTap: () => onChanged(p),
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 250),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: isSel
                              ? const Color(0xFF0E2A24)
                              : StatsColors.mint,
                        ),
                        child: Text(p.label),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final Widget child;

  const _StatCard({
    required this.title,
    required this.value,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: StatsColors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: StatsColors.cardBorder, width: 1.2),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: StatsColors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _FadeText(
                text: value,
                alignment: Alignment.centerRight,
                style: const TextStyle(
                  fontFamily: kSerif,
                  fontFamilyFallback: kSerifFallback,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: StatsColors.mint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _MiniTile extends StatelessWidget {
  final String value;
  final String label;

  const _MiniTile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 84),
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      decoration: BoxDecoration(
        color: StatsColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: StatsColors.cardBorder, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FadeText(
            text: value,
            alignment: Alignment.centerLeft,
            style: const TextStyle(
              fontFamily: kSerif,
              fontFamilyFallback: kSerifFallback,
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: StatsColors.white,
              height: 1.15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: StatsColors.label, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// Text that cross-fades when its value changes.
class _FadeText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Alignment alignment;

  const _FadeText({
    required this.text,
    required this.style,
    required this.alignment,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.25),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: Text(text, key: ValueKey(text), style: style),
    );
  }
}

/// ---------------------------------------------------------------------------
/// PAINTERS
/// ---------------------------------------------------------------------------
class _LinePainter extends CustomPainter {
  final List<double> v; // 0..1

  _LinePainter(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2) return;
    const pad = 3.0;
    final dx = (size.width - pad * 2) / (v.length - 1);

    final path = Path();
    for (int i = 0; i < v.length; i++) {
      final x = pad + dx * i;
      final y = pad + (1 - v[i]) * (size.height - pad * 2);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = StatsColors.mint,
    );
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

class _BarsPainter extends CustomPainter {
  final List<double> v; // 0..1

  _BarsPainter(this.v);

  @override
  void paint(Canvas canvas, Size size) {
    final n = v.length;
    final slot = size.width / n;
    final barW = slot * 0.72;

    for (int i = 0; i < n; i++) {
      final h = math.max(size.height * 0.12, v[i] * size.height);
      final left = i * slot + (slot - barW) / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - h, barW, h),
        const Radius.circular(6),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = i == n - 1 ? StatsColors.mint : StatsColors.bar,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => true;
}