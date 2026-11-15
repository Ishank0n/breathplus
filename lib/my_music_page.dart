import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'audio_state.dart';
import 'audio_widgets.dart';

/// MY MUSIC tab: audio the user imported from their device.
class MyMusicPage extends StatelessWidget {
  const MyMusicPage({super.key});

  void _remove(BuildContext context, AudioTrack t) {
    final messenger = ScaffoldMessenger.of(context);
    HapticFeedback.selectionClick();
    final index = audio.removeImported(t);
    if (index < 0) return;
    audioSnack(
      messenger,
      'Removed "${t.title}"',
      actionLabel: 'Undo',
      onAction: () => audio.restoreImported(t, index),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: audio,
      builder: (context, _) {
        final tracks = audio.imported;

        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: NowPlayingCard(),
            ),
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  AudioHeading(
                    tracks.isEmpty
                        ? 'Your tracks'
                        : 'Your tracks (${tracks.length})',
                  ),
                  const Spacer(),
                  if (tracks.isNotEmpty)
                    Pressable(
                      pressedScale: 0.94,
                      onTap: () => runImport(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.cardBorder,
                            width: 1.4,
                          ),
                        ),
                        child: audio.importing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      AppColors.mint),
                                ),
                              )
                            : const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.add_rounded,
                                      size: 16, color: AppColors.mint),
                                  SizedBox(width: 4),
                                  Text(
                                    'Import',
                                    style: TextStyle(
                                      color: AppColors.mint,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: tracks.isEmpty
                    ? const _EmptyState(key: ValueKey('empty'))
                    : ListView.builder(
                        key: const ValueKey('list'),
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: tracks.length,
                        itemBuilder: (context, i) {
                          final t = tracks[i];
                          return TrackTile(
                            key: ValueKey(t.id),
                            track: t,
                            isCurrent: audio.current?.id == t.id,
                            isPlaying: audio.isPlaying,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              audio.toggle(t);
                            },
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (audio.chosen.contains(t.id))
                                  const Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: Icon(Icons.check_circle_rounded,
                                        size: 18, color: AppColors.mint),
                                  ),
                                Pressable(
                                  pressedScale: 0.85,
                                  onTap: () => _remove(context, t),
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(
                                      Icons.delete_outline_rounded,
                                      size: 22,
                                      color: AppColors.mintText,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x66152B5C), // card navy (was green)
                border: Border.all(
                  color: AppColors.cardBorder,
                  width: 1.2,
                ),
              ),
              child: const Icon(
                Icons.library_music_outlined,
                size: 36,
                color: AppColors.mint,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'No music yet',
              style: TextStyle(
                fontFamily: kSerif,
                fontFamilyFallback: kSerifFallback,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: AppColors.white,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Import audio from your device to play it during your sessions.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.mintText,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 180,
              child: AnimatedBuilder(
                animation: audio,
                builder: (context, _) => AudioPillButton(
                  label: 'Import audio',
                  loading: audio.importing,
                  onTap: () => runImport(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
