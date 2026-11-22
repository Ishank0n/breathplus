import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ---------------------------------------------------------------------------
/// MODELS
/// ---------------------------------------------------------------------------
String fmtDuration(int seconds) =>
    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

String _fmtSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).round()} KB';
}

String _fileName(String path) => path.split(RegExp(r'[\\/]')).last;

class AudioTrack {
  final String id;
  final String title;
  final String category;
  final int seconds;
  final bool imported;
  final String? path; // file path of imported audio (null on web)
  final String? assetPath; // bundled audio asset for Library tracks
  final int? bytes;
  final String? ext;

  const AudioTrack({
    required this.id,
    required this.title,
    required this.category,
    required this.seconds,
    this.imported = false,
    this.path,
    this.assetPath,
    this.bytes,
    this.ext,
  });

  String get subtitle {
    if (!imported) return '$category · ${fmtDuration(seconds)}';
    final parts = <String>['Imported'];
    if (ext != null && ext!.isNotEmpty) parts.add(ext!.toUpperCase());
    if (seconds > 0) parts.add(fmtDuration(seconds));
    final size = _fmtSize(bytes);
    if (size.isNotEmpty) parts.add(size);
    return parts.join(' · ');
  }
}

class ImportResult {
  final int added;
  final int skipped;
  final bool cancelled;
  final String? error;

  const ImportResult({
    this.added = 0,
    this.skipped = 0,
    this.cancelled = false,
    this.error,
  });
}

/// ---------------------------------------------------------------------------
/// CONTROLLER  (shared by Library and My music)
///
/// Imported tracks are copied into the app's own storage and remembered
/// between launches. Library tracks play bundled assets through `just_audio`.
/// Add the corresponding MP3 files under assets/audio/ using the filenames
/// listed below. Imported tracks continue to work independently.
/// ---------------------------------------------------------------------------
AudioController get audio => AudioController.instance;

class AudioController extends ChangeNotifier {
  AudioController._() {
    current = library.first;
    _ready = _init();
  }

  static final AudioController instance = AudioController._();

  static const _prefsTracks = 'imported_tracks_v1';
  static const _prefsChosen = 'chosen_tracks_v1';
  static const _folderName = 'imported_audio';
  static const _undoWindow = Duration(seconds: 6);

  /// Bundled Library tracks. Add these files to assets/audio/ and register
  /// that directory in pubspec.yaml. The filenames are intentionally stable.
  final List<AudioTrack> library = const [
    AudioTrack(id: 'lib_rain', title: 'Rain on Leaves', category: 'Nature', seconds: 480, assetPath: 'assets/audio/rain_on_leaves.mpeg'),
    AudioTrack(id: 'lib_dawn', title: 'Forest Dawn', category: 'Nature', seconds: 390, assetPath: 'assets/audio/forest_dawn.mpeg'),
    AudioTrack(id: 'lib_stream', title: 'Stream Hush', category: 'Nature', seconds: 600, assetPath: 'assets/audio/stream_hush.mpeg'),
    AudioTrack(id: 'lib_bamboo', title: 'Wind in Bamboo', category: 'Ambient', seconds: 435, assetPath: 'assets/audio/wind_in_bamboo.mpeg'),
    AudioTrack(id: 'lib_birds', title: 'Morning Birdsong', category: 'Nature', seconds: 555, assetPath: 'assets/audio/morning_birdsong.mpeg'),
    AudioTrack(id: 'lib_thunder', title: 'Soft Thunder', category: 'Ambient', seconds: 720, assetPath: 'assets/audio/soft_thunder.mpeg'),
  ];

  final List<AudioTrack> imported = [];
  final Set<String> chosen = {};

  AudioTrack? current;
  bool isPlaying = false;
  double progress = 0;
  Duration position = Duration.zero;
  Duration? duration;

  bool importing = false;

  /// True once saved tracks have been loaded from storage.
  bool loaded = false;

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _subs = [];
  final Map<String, Timer> _pendingDeletes = {};
  late final Future<void> _ready;
  Directory? _dir;
  Timer? _timer;
  int _loadToken = 0;
  bool _loading = false;

  List<AudioTrack> get allTracks => [...library, ...imported];

  bool _isFile(AudioTrack? t) => !kIsWeb && t?.path != null;

  bool _hasAudioSource(AudioTrack? t) =>
      t != null && (t.assetPath != null || _isFile(t));

  // ---- Startup ----------------------------------------------------------------
  Future<void> _init() async {
    try {
      // Lets audio play even when the iPhone's silent switch is on.
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('Audio session setup failed: $e');
    }

    _subs.add(_player.positionStream.listen(_onPosition));
    _subs.add(_player.playerStateStream.listen(_onPlayerState));

    if (!kIsWeb) {
      try {
        await _loadSaved();
      } catch (e) {
        debugPrint('Could not load saved tracks: $e');
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<Directory> _audioDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_folderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = await _audioDir();
    final keep = <String>{};
    var missing = false;

    final raw = prefs.getString(_prefsTracks);
    if (raw != null) {
      for (final item in jsonDecode(raw) as List) {
        final m = item as Map<String, dynamic>;
        final name = m['file'] as String;
        // Only the file name is stored: on iOS the app folder path can change
        // between updates, so the full path is rebuilt on every launch.
        final file = File('${dir.path}/$name');
        if (!await file.exists()) {
          missing = true;
          continue;
        }
        keep.add(name);
        imported.add(AudioTrack(
          id: m['id'] as String,
          title: m['title'] as String,
          category: 'Imported',
          seconds: (m['seconds'] as int?) ?? 0,
          imported: true,
          path: file.path,
          bytes: m['bytes'] as int?,
          ext: m['ext'] as String?,
        ));
      }
    }
    chosen.addAll(prefs.getStringList(_prefsChosen) ?? const []);

    // Clean up files nothing points to (e.g. app closed during an undo window).
    await for (final entity in dir.list()) {
      if (entity is File && !keep.contains(_fileName(entity.path))) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    if (missing) await _save();
  }

  Future<void> _save() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = imported
          .where((t) => t.path != null)
          .map((t) => {
                'id': t.id,
                'title': t.title,
                'file': _fileName(t.path!),
                'seconds': t.seconds,
                'bytes': t.bytes,
                'ext': t.ext,
              })
          .toList();
      await prefs.setString(_prefsTracks, jsonEncode(data));
      await prefs.setStringList(_prefsChosen, chosen.toList());
    } catch (e) {
      debugPrint('Could not save tracks: $e');
    }
  }

  // ---- Player events ----------------------------------------------------------
  void _onPosition(Duration p) {
    if (!_hasAudioSource(current) || _loading) return;
    position = p;
    final d = duration ?? _player.duration;
    if (d != null && d.inMilliseconds > 0) {
      duration = d;
      progress = (p.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0).toDouble();
    }
    notifyListeners();
  }

  void _onPlayerState(PlayerState s) {
    if (!_hasAudioSource(current) || _loading) return;
    if (s.processingState == ProcessingState.completed) {
      // Same behaviour as before: an imported track stops at the end.
      isPlaying = false;
      progress = 0;
      position = Duration.zero;
      unawaited(_player.pause());
      unawaited(_player.seek(Duration.zero));
      notifyListeners();
      return;
    }
    // Keeps the UI right when the system pauses audio (calls, headphones out).
    if (s.processingState == ProcessingState.ready && s.playing != isPlaying) {
      isPlaying = s.playing;
      notifyListeners();
    }
  }

  // ---- Tracks -----------------------------------------------------------------
  Future<void> toggle(AudioTrack t) async {
    if (current?.id == t.id) {
      if (isPlaying) {
        _pause();
      } else {
        await _resume();
      }
      return;
    }

    current = t;
    progress = 0;
    position = Duration.zero;
    duration = null;
    isPlaying = true;
    notifyListeners();

    if (_hasAudioSource(t)) {
      _stopTimer();
      await _loadAndPlay(t);
    } else {
      _loadToken++;
      _loading = false;
      await _player.stop();
      _syncTimer();
    }
  }

  void _pause() {
    isPlaying = false;
    if (_hasAudioSource(current)) unawaited(_player.pause());
    _syncTimer();
    notifyListeners();
  }

  Future<void> _resume() async {
    final t = current;
    if (t == null) return;
    isPlaying = true;
    notifyListeners();

    if (!_hasAudioSource(t)) {
      _syncTimer();
      return;
    }
    if (_player.processingState == ProcessingState.idle) {
      await _loadAndPlay(t, from: position);
    } else {
      unawaited(_player.play());
    }
  }

  Future<void> _loadAndPlay(AudioTrack t, {Duration? from}) async {
    final token = ++_loadToken;
    _loading = true;
    try {
      final d = t.assetPath != null
          ? await _player.setAsset(t.assetPath!, initialPosition: from)
          : await _player.setFilePath(t.path!, initialPosition: from);
      if (token != _loadToken) return; // another track was tapped meanwhile
      duration = d;
      _loading = false;
      // play() completes only when playback stops, so it isn't awaited.
      if (isPlaying) unawaited(_player.play());
      notifyListeners();
    } catch (e) {
      if (token != _loadToken) return;
      _loading = false;
      debugPrint('Could not play "${t.title}". Check that ${t.assetPath ?? t.path} exists and is registered in pubspec.yaml. Error: $e');
      isPlaying = false;
      notifyListeners();
    }
  }

  void seek(double v) {
    progress = v.clamp(0.0, 1.0).toDouble();
    final d = duration;
    if (_hasAudioSource(current) && d != null) {
      position = d * progress;
      unawaited(_player.seek(position));
    }
    notifyListeners();
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// Retains simulated progress only for tracks without an audio source.
  /// Bundled Library tracks and imported files use the real audio player.
  void _syncTimer() {
    _stopTimer();
    final t = current;
    if (!isPlaying || t == null || _hasAudioSource(t)) return;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final t = current;
      if (t == null || t.seconds <= 0) return;
      progress += 0.25 / t.seconds;
      if (progress >= 1) {
        progress = 0;
        if (t.imported) {
          isPlaying = false;
          _stopTimer();
        }
      }
      notifyListeners();
    });
  }

  void setChosen(Set<String> ids) {
    chosen
      ..clear()
      ..addAll(ids);
    unawaited(_save());
    notifyListeners();
  }

  // ---- Imported audio -------------------------------------------------------
  int removeImported(AudioTrack t) {
    final index = imported.indexWhere((e) => e.id == t.id);
    if (index < 0) return -1;
    imported.removeAt(index);
    chosen.remove(t.id);
    if (current?.id == t.id) {
      _loadToken++;
      _loading = false;
      current = library.first;
      progress = 0;
      position = Duration.zero;
      duration = null;
      isPlaying = false;
      unawaited(_player.stop());
      _syncTimer();
    }
    _scheduleFileDelete(t);
    unawaited(_save());
    notifyListeners();
    return index;
  }

  void restoreImported(AudioTrack t, int index) {
    _pendingDeletes.remove(t.id)?.cancel();
    imported.insert(index.clamp(0, imported.length), t);
    unawaited(_save());
    notifyListeners();
  }

  /// The file is kept until the Undo window has passed.
  void _scheduleFileDelete(AudioTrack t) {
    final path = t.path;
    if (kIsWeb || path == null) return;
    _pendingDeletes.remove(t.id)?.cancel();
    _pendingDeletes[t.id] = Timer(_undoWindow, () async {
      _pendingDeletes.remove(t.id);
      try {
        await File(path).delete();
      } catch (_) {}
    });
  }

  static String _titleOf(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /// Opens the system file picker, copies the chosen audio into the app's
  /// storage and adds it to My music.
  Future<ImportResult> importAudio() async {
    if (importing) return const ImportResult(cancelled: true);
    importing = true;
    notifyListeners();

    AudioPlayer? probe; // reads each file's length without touching playback
    try {
      await _ready;

      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'mp3',
          'm4a',
          'aac',
          'wav',
          'flac',
          'ogg',
          'opus',
        ],
        allowMultiple: true,
        withData: false,
      );

      if (res == null || res.files.isEmpty) {
        return const ImportResult(cancelled: true);
      }

      final dir = kIsWeb ? null : await _audioDir();
      int added = 0;
      int skipped = 0;
      int failed = 0;

      for (var i = 0; i < res.files.length; i++) {
        final f = res.files[i];
        final title = _titleOf(f.name);
        final duplicate =
            imported.any((t) => t.title == title && t.bytes == f.size);
        if (duplicate) {
          skipped++;
          continue;
        }

        final id = 'imp_${DateTime.now().microsecondsSinceEpoch}_$i';
        String? savedPath;
        int seconds = 0;

        if (!kIsWeb) {
          if (f.path == null) {
            failed++;
            continue;
          }
          try {
            final ext = (f.extension ?? 'audio').toLowerCase();
            final dest = '${dir!.path}/$id.$ext';
            // The picker's path is a temporary copy the system may delete,
            // so the file is copied into the app's own documents folder.
            await File(f.path!).copy(dest);
            savedPath = dest;
          } catch (e) {
            debugPrint('Could not copy ${f.name}: $e');
            failed++;
            continue;
          }
          try {
            probe ??= AudioPlayer();
            final d = await probe.setFilePath(savedPath);
            seconds = d?.inSeconds ?? 0;
          } catch (_) {
            // Unreadable length is fine; the track can still be tried.
          }
        }

        imported.add(
          AudioTrack(
            id: id,
            title: title,
            category: 'Imported',
            seconds: seconds,
            imported: true,
            path: savedPath,
            bytes: f.size,
            ext: f.extension,
          ),
        );
        added++;
      }

      if (added > 0) await _save();
      if (added == 0 && failed > 0) {
        return const ImportResult(
          error: 'Could not import audio. Please try again.',
        );
      }
      return ImportResult(added: added, skipped: skipped + failed);
    } catch (e) {
      debugPrint('Import failed: $e');
      return const ImportResult(
        error: 'Could not import audio. Please try again.',
      );
    } finally {
      await probe?.dispose();
      importing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _stopTimer();
    for (final t in _pendingDeletes.values) {
      t.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}