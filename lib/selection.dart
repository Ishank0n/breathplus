import 'package:flutter/material.dart';

// Shared pieces (World colours, glyph icons, phone frame, serif style)
// already live in band_screen.dart, so they are not repeated here.
import 'band_screen.dart'
    show GlyphIcon, PhoneFrame, World, plantsWorld, celestialWorld, serif;

/// First screen of the app: choose between Plants and Space.
///
/// [plantsBuilder] should return the root widget of your existing project.
/// [onSpace] opens the Space app when the Space button is tapped.
class ModeSelectionScreen extends StatelessWidget {
  final WidgetBuilder plantsBuilder;
  final VoidCallback? onSpace;

  const ModeSelectionScreen({
    super.key,
    required this.plantsBuilder,
    this.onSpace,
  });

  void _openPlants(BuildContext context) {
    // pushReplacement so the back button doesn't return to this screen.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: plantsBuilder),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF08130F),
      body: PhoneFrame(
        outside: const Color(0xFF08130F),
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF12301F),
                Color(0xFF0D1F1A),
                Color(0xFF091510),
              ],
            ),
          ),
          child: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 8),
                Text('Choose your world', style: serif(28, color: Colors.white)),
                const SizedBox(height: 4),
                const Text(
                  'Same breathing techniques, two ways to grow.',
                  style: TextStyle(color: Color(0xFFA9DCB9), fontSize: 14),
                ),
                const SizedBox(height: 18),
                _ModeCard(
                  world: plantsWorld,
                  title: 'Plants',
                  subtitle: 'Grow a garden, one breath at a time.',
                  button: 'Choose Plants',
                  glyphKind: 0,
                  gradient: const [Color(0xFF1B3D2A), Color(0xFF0F2216)],
                  border: const Color(0x408CE6A0),
                  onTap: () => _openPlants(context),
                ),
                const SizedBox(height: 18),
                _ModeCard(
                  world: celestialWorld,
                  title: 'Space',
                  subtitle: 'Drift through deep space, one breath at a time.',
                  button: 'Choose Space',
                  glyphKind: 1,
                  gradient: const [
                    Color(0xFF0F2544),
                    Color(0xFF071120),
                  ],
                  border: const Color(0x4D60A5FA),
                  onTap: onSpace ?? () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final World world;
  final String title, subtitle, button;
  final int glyphKind;
  final List<Color> gradient;
  final Color border;
  final VoidCallback onTap;

  const _ModeCard({
    required this.world,
    required this.title,
    required this.subtitle,
    required this.button,
    required this.glyphKind,
    required this.gradient,
    required this.border,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: border),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: gradient,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 150,
            child: Center(
              child: glyphKind == 1
                  ? Image.asset(
                      'assets/spiral_galaxy.png',
                      width: 110,
                      height: 110,
                      fit: BoxFit.contain,
                    )
                  : GlyphIcon(
                      celestial: world.celestial,
                      kind: glyphKind,
                      size: 110,
                    ),
            ),
          ),
          Text(title, style: serif(24, color: Colors.white)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: world.muted, fontSize: 14)),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                backgroundColor: world.accent,
                foregroundColor: world.ink,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: const StadiumBorder(),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
              child: Text(button),
            ),
          ),
        ],
      ),
    );
  }
}
