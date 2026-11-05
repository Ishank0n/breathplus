import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Re-uses Pressable, kSerif, kSerifFallback (main.dart) and StatsColors
import 'main.dart';
import 'stats_page.dart';
import 'band_screen.dart';
import 'reminder_service.dart';

/// ---------------------------------------------------------------------------
/// PLACEHOLDER DATA  (replace with real data / state management)
/// ---------------------------------------------------------------------------
class ProfileData {
  static const String name = 'Your name';
  static const String email = 'you@email.com';
  static const int bandBattery = 78;
  static const String bandLastSync = '2 min ago';
  static const String footnote =
      'Breathe+ supports stress management and well-being. It does not '
      'diagnose or treat any condition.';
}

class _C {
  static const bg = StatsColors.card;
  static const border = StatsColors.cardBorder;
  static const mint = StatsColors.mint;
  static const white = StatsColors.white;
  static const dark = Color(0xFF0E2A24);
  static const divider = Color(0xFF2A4B53);
  static const subtle = Color(0xFF8FD0BE);
  static const avatar = Color(0xFFB9A2FF);
  static const avatarText = Color(0xFF1B1740);
  static const danger = Color(0xFFFF9C94);
}

/// ---------------------------------------------------------------------------
/// PROFILE PAGE
/// ---------------------------------------------------------------------------
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with SingleTickerProviderStateMixin {
  // Settings state (placeholders)
  bool _lightCues = true;
  bool _hapticCues = true;
  bool _dailyReminder = false; // loaded from storage in initState
  TimeOfDay _time = const TimeOfDay(hour: 20, minute: 0);
  int _goal = 1;
  String _units = 'Metric';
  bool _bandPaired = true;
  final Map<String, bool> _health = {
    'Heart rate': true,
    'Blood oxygen': true,
    'Steps': true,
    'Calories burnt': false,
  };

  late final AnimationController _intro;

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..forward();
    _loadReminder();
  }

  Future<void> _loadReminder() async {
    final s = await ReminderService.instance.load();
    if (!mounted) return;
    setState(() {
      _dailyReminder = s.enabled;
      _time = TimeOfDay(hour: s.hour, minute: s.minute);
    });
  }

  Future<void> _toggleReminder() async {
    HapticFeedback.selectionClick();
    if (!_dailyReminder) {
      final ok = await ReminderService.instance.enable(_time);
      if (!mounted) return;
      if (!ok) {
        _snack(ReminderService.instance.supported
            ? 'Allow notifications in your phone settings to get reminders'
            : 'Reminders only work in the phone app');
        return;
      }
      setState(() => _dailyReminder = true);
      _snack('Daily reminder set for ${_time.format(context)}');
    } else {
      await ReminderService.instance.disable();
      if (!mounted) return;
      setState(() => _dailyReminder = false);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    super.dispose();
  }

  Widget _stagger(int index, Widget child) {
    final begin = (index * 0.06).clamp(0.0, 0.6).toDouble();
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

  // ---- Helpers ---------------------------------------------------------------
  void _toggle(bool current, ValueChanged<bool> set) {
    HapticFeedback.selectionClick();
    setState(() => set(!current));
  }

  void _snack(String message) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: _C.bg,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: _C.border),
        ),
        content: Text(message, style: const TextStyle(color: _C.white)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openSheet(WidgetBuilder builder) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: const Color(0xAA000000),
      builder: builder,
    );
  }

  // ---- Row actions -----------------------------------------------------------
  void _connectBand() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BandScreen(
          connected: _bandPaired,
          onConnectedChanged: (v) => setState(() => _bandPaired = v),
        ),
      ),
    );
  }

  void _openBand() {
    _openSheet(
      (_) => _BandSheet(
        paired: _bandPaired,
        battery: ProfileData.bandBattery,
        lastSync: ProfileData.bandLastSync,
        onPairedChanged: (v) => setState(() => _bandPaired = v),
      ),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: _C.mint,
            onPrimary: _C.dark,
            surface: _C.bg,
            onSurface: _C.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() => _time = picked);
      await ReminderService.instance.updateTime(picked);
      if (!mounted) return;
      _snack('Reminder set for ${picked.format(context)}');
    }
  }

  void _openGoal() {
    _openSheet(
      (_) => _OptionSheet<int>(
        title: 'Daily streak goal',
        options: const [1, 2, 3, 5],
        selected: _goal,
        labelOf: (n) => n == 1 ? '1 session' : '$n sessions',
        onChanged: (v) => setState(() => _goal = v),
      ),
    );
  }

  void _openHealth() {
    _openSheet(
      (_) => _HealthSheet(
        values: Map<String, bool>.from(_health),
        onChanged: (k, v) => setState(() => _health[k] = v),
      ),
    );
  }

  void _openUnits() {
    _openSheet(
      (_) => _OptionSheet<String>(
        title: 'Units',
        options: const ['Metric', 'Imperial'],
        selected: _units,
        labelOf: (s) => s,
        onChanged: (v) => setState(() => _units = v),
      ),
    );
  }

  void _openPrivacy() {
    _openSheet(
      (_) => _PrivacySheet(
        // TODO: open real links with url_launcher
        onSelect: (label) => _snack('$label: add your link here'),
      ),
    );
  }

  // ---- Build -----------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final initial =
        ProfileData.name.isEmpty ? '?' : ProfileData.name[0].toUpperCase();

    final rows = <Widget>[
      _SettingRow(
        label: 'Band',
        trailing: _ValueText(
          _bandPaired
              ? 'Paired · ${ProfileData.bandBattery}%'
              : 'Not paired',
        ),
        onTap: _openBand,
      ),
      _SettingRow(
        label: 'Light cues',
        trailing: _CheckBox(value: _lightCues),
        onTap: () => _toggle(_lightCues, (v) => _lightCues = v),
      ),
      _SettingRow(
        label: 'Haptic cues',
        trailing: _CheckBox(value: _hapticCues),
        onTap: () => _toggle(_hapticCues, (v) => _hapticCues = v),
      ),
      _SettingRow(
        label: 'Daily reminder',
        trailing: _CheckBox(value: _dailyReminder),
        onTap: _toggleReminder,
      ),
      _SettingRow(
        label: 'Reminder time',
        dim: !_dailyReminder,
        trailing: _ValueText(_time.format(context)),
        onTap: _pickTime,
      ),
      _SettingRow(
        label: 'Daily streak goal',
        trailing: _ValueText(_goal == 1 ? '1 session' : '$_goal sessions'),
        onTap: _openGoal,
      ),
      _SettingRow(
        label: 'Health data access',
        trailing: const _ValueText('Manage'),
        onTap: _openHealth,
      ),
      _SettingRow(
        label: 'Units',
        trailing: _ValueText(_units),
        onTap: _openUnits,
      ),
      _SettingRow(
        label: 'Privacy and help',
        trailing: const SizedBox.shrink(),
        onTap: _openPrivacy,
      ),
    ];

    // Own opaque background so the shell's green gradient never shows through.
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [StatsColors.bgTop, StatsColors.bgBottom],
        ),
      ),
      child: SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _stagger(
              0,
              const Text(
                'You and settings',
                style: TextStyle(
                  fontFamily: kSerif,
                  fontFamilyFallback: kSerifFallback,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: _C.white,
                ),
              ),
            ),
            const SizedBox(height: 14),
            _stagger(
              1,
              Row(
                children: [
                  Container(
                    width: 62,
                    height: 62,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _C.avatar,
                    ),
                    child: Text(
                      initial,
                      style: const TextStyle(
                        fontFamily: kSerif,
                        fontFamilyFallback: kSerifFallback,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: _C.avatarText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        ProfileData.name,
                        style: TextStyle(
                          fontFamily: kSerif,
                          fontFamilyFallback: kSerifFallback,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: _C.white,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        ProfileData.email,
                        style: TextStyle(color: _C.subtle, fontSize: 12.5),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _stagger(
              2,
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: _C.bg,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: _C.border, width: 1.2),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(21),
                  child: Column(
                    children: [
                      const SizedBox(height: 6),
                      for (int i = 0; i < rows.length; i++)
                        _stagger(3 + i, rows[i]),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            ProfileData.footnote,
                            style: TextStyle(
                              color: _C.subtle,
                              fontSize: 10.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            _stagger(
              3 + rows.length,
              _PillButton(
                label: _bandPaired ? 'Manage band' : 'Connect band',
                onTap: _connectBand,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// ROW WIDGETS
/// ---------------------------------------------------------------------------
class _RowTap extends StatefulWidget {
  final VoidCallback onTap;
  final Widget child;

  const _RowTap({required this.onTap, required this.child});

  @override
  State<_RowTap> createState() => _RowTapState();
}

class _RowTapState extends State<_RowTap> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: _down ? const Color(0x1A7FE3C5) : Colors.transparent,
        child: widget.child,
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;
  final Widget trailing;
  final VoidCallback onTap;
  final bool dim;

  const _SettingRow({
    required this.label,
    required this.trailing,
    required this.onTap,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _RowTap(
          onTap: onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: dim ? 0.45 : 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: _C.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  trailing,
                ],
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            height: 1,
            child: DecoratedBox(decoration: BoxDecoration(color: _C.divider)),
          ),
        ),
      ],
    );
  }
}

class _ValueText extends StatelessWidget {
  final String text;

  const _ValueText(this.text);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerRight,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: Text(
        text,
        key: ValueKey(text),
        style: const TextStyle(color: _C.mint, fontSize: 13.5),
      ),
    );
  }
}

class _CheckBox extends StatelessWidget {
  final bool value;

  const _CheckBox({required this.value});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: value ? _C.white : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _C.white, width: 1.6),
      ),
      child: AnimatedScale(
        scale: value ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutBack,
        child: const Icon(Icons.check_rounded, size: 18, color: _C.dark),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;

  const _Toggle({required this.value});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 46,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? _C.mint : const Color(0xFF2B4D55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: value ? _C.dark : _C.white,
          ),
        ),
      ),
    );
  }
}

/// ---------------------------------------------------------------------------
/// BOTTOM SHEETS
/// ---------------------------------------------------------------------------
class _SheetFrame extends StatelessWidget {
  final String title;
  final Widget child;

  const _SheetFrame({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: _C.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(top: BorderSide(color: _C.border, width: 1.2)),
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: _C.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              fontFamily: kSerif,
              fontFamilyFallback: kSerifFallback,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: _C.white,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool filled;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  const _PillButton({
    required this.label,
    required this.onTap,
    this.filled = true,
    this.enabled = true,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: enabled ? onTap : () {},
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1 : 0.45,
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: filled ? _C.mint : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            border: filled ? null : Border.all(color: _C.border, width: 1.3),
          ),
          child: loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    valueColor: AlwaysStoppedAnimation<Color>(_C.dark),
                  ),
                )
              : Text(
                  label,
                  style: TextStyle(
                    color: filled ? _C.dark : _C.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Band: status, battery, sync and pair / unpair.
class _BandSheet extends StatefulWidget {
  final bool paired;
  final int battery;
  final String lastSync;
  final ValueChanged<bool> onPairedChanged;

  const _BandSheet({
    required this.paired,
    required this.battery,
    required this.lastSync,
    required this.onPairedChanged,
  });

  @override
  State<_BandSheet> createState() => _BandSheetState();
}

class _BandSheetState extends State<_BandSheet> {
  late bool _paired = widget.paired;
  late String _lastSync = widget.lastSync;
  bool _syncing = false;

  Future<void> _sync() async {
    setState(() => _syncing = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _lastSync = 'Just now';
    });
  }

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(k,
                  style: const TextStyle(color: _C.subtle, fontSize: 13.5)),
            ),
            Text(v,
                style: const TextStyle(
                    color: _C.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      title: 'Band',
      child: Column(
        children: [
          _info('Status', _paired ? 'Paired' : 'Not paired'),
          _info('Battery', _paired ? '${widget.battery}%' : '--'),
          _info('Last sync', _paired ? _lastSync : '--'),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _PillButton(
                  label: 'Sync now',
                  loading: _syncing,
                  enabled: _paired && !_syncing,
                  onTap: _sync,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PillButton(
                  label: _paired ? 'Unpair' : 'Pair band',
                  filled: false,
                  onTap: () {
                    setState(() => _paired = !_paired);
                    widget.onPairedChanged(_paired);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Generic single-choice sheet (streak goal, units).
class _OptionSheet<T> extends StatefulWidget {
  final String title;
  final List<T> options;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  const _OptionSheet({
    required this.title,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  @override
  State<_OptionSheet<T>> createState() => _OptionSheetState<T>();
}

class _OptionSheetState<T> extends State<_OptionSheet<T>> {
  late T _sel = widget.selected;

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      title: widget.title,
      child: Column(
        children: widget.options.map((o) {
          final on = o == _sel;
          return _RowTap(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _sel = o);
              widget.onChanged(o);
              Future.delayed(const Duration(milliseconds: 220), () {
                if (mounted) Navigator.of(context).pop();
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.labelOf(o),
                      style: TextStyle(
                        color: on ? _C.mint : _C.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: on ? _C.mint : _C.border,
                        width: 2,
                      ),
                    ),
                    child: AnimatedScale(
                      scale: on ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutBack,
                      child: Container(
                        width: 11,
                        height: 11,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _C.mint,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Health data access toggles.
class _HealthSheet extends StatefulWidget {
  final Map<String, bool> values;
  final void Function(String key, bool value) onChanged;

  const _HealthSheet({required this.values, required this.onChanged});

  @override
  State<_HealthSheet> createState() => _HealthSheetState();
}

class _HealthSheetState extends State<_HealthSheet> {
  late final Map<String, bool> _v = Map<String, bool>.from(widget.values);

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      title: 'Health data access',
      child: Column(
        children: [
          for (final e in _v.entries)
            _RowTap(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _v[e.key] = !e.value);
                widget.onChanged(e.key, _v[e.key]!);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.key,
                        style: const TextStyle(
                          color: _C.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _Toggle(value: e.value),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 14),
          _PillButton(
            label: 'Done',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Privacy and help links.
class _PrivacySheet extends StatelessWidget {
  final ValueChanged<String> onSelect;

  const _PrivacySheet({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    const items = <String>[
      'Privacy policy',
      'Terms of use',
      'Help center',
      'Contact support',
      'Delete my data',
    ];
    return _SheetFrame(
      title: 'Privacy and help',
      child: Column(
        children: items.map((label) {
          final danger = label == 'Delete my data';
          return _RowTap(
            onTap: () {
              Navigator.of(context).pop();
              onSelect(label);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: danger ? _C.danger : _C.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: danger ? _C.danger : _C.subtle,
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}