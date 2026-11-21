import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class TrackAnalysis {
  const TrackAnalysis({
    required this.bpm,
    required this.key,
    required this.beatOffset,
  });

  final double bpm;
  final int key;
  final double beatOffset;
}

/// Tempo, key and beat grid plus a loudness envelope (one value per 0.5 s).
class TrackStructure extends TrackAnalysis {
  const TrackStructure({
    required super.bpm,
    required super.key,
    required super.beatOffset,
    required this.durationSec,
    required this.env,
  });

  final double durationSec;
  final List<double> env;
}

typedef _AnalyzeC = Int32 Function(
  Pointer<Utf8>,
  Pointer<Float>,
  Pointer<Int32>,
  Pointer<Float>,
);

DynamicLibrary _openLib() {
  return Platform.isAndroid
      ? DynamicLibrary.open('libdj_engine.so')
      : DynamicLibrary.process();
}

/// Decode + BPM/key. No deck involved. Safe to call from a worker isolate.
TrackAnalysis? analyzeTrackFile(String path) {
  final lib = _openLib();
  final fn = lib.lookupFunction<_AnalyzeC, int Function(
    Pointer<Utf8>,
    Pointer<Float>,
    Pointer<Int32>,
    Pointer<Float>,
  )>('dj_analyze_file');
  final p = path.toNativeUtf8();
  final bpm = malloc<Float>();
  final key = malloc<Int32>();
  final offset = malloc<Float>();
  try {
    if (fn(p, bpm, key, offset) != 1) {
      return null;
    }
    return TrackAnalysis(
      bpm: bpm.value,
      key: key.value,
      beatOffset: offset.value,
    );
  } finally {
    malloc.free(p);
    malloc.free(bpm);
    malloc.free(key);
    malloc.free(offset);
  }
}

Future<TrackAnalysis?> analyzeTrackFileOffUi(String path) async {
  try {
    return await Isolate.run(() => analyzeTrackFile(path));
  } catch (_) {
    return analyzeTrackFile(path);
  }
}

/// Seconds of audio that really decode from the file (decodes all of it).
double fileDecodedSec(String path) {
  final lib = _openLib();
  final fn = lib.lookupFunction<Double Function(Pointer<Utf8>), double Function(Pointer<Utf8>)>(
    'dj_file_decoded_seconds',
  );
  final p = path.toNativeUtf8();
  try {
    return fn(p);
  } finally {
    malloc.free(p);
  }
}

double fileDurationSec(String path) {
  final lib = _openLib();
  final fn = lib.lookupFunction<Double Function(Pointer<Utf8>), double Function(Pointer<Utf8>)>(
    'dj_file_duration',
  );
  final p = path.toNativeUtf8();
  try {
    return fn(p);
  } finally {
    malloc.free(p);
  }
}


typedef _StructC = Int32 Function(Pointer<Utf8>, Pointer<Float>, Pointer<Int32>, Pointer<Float>,
    Pointer<Float>, Int32, Pointer<Int32>, Pointer<Float>);
typedef _StructD = int Function(Pointer<Utf8>, Pointer<Float>, Pointer<Int32>, Pointer<Float>,
    Pointer<Float>, int, Pointer<Int32>, Pointer<Float>);

/// One decode gives tempo, key, beat grid and the loudness envelope.
TrackStructure? analyzeTrackStructure(String path) {
  final lib = _openLib();
  final fn = lib.lookupFunction<_StructC, _StructD>('dj_analyze_structure');
  const cap = 4000; // 2000 s of 0.5 s bins
  final p = path.toNativeUtf8();
  final bpm = malloc<Float>();
  final key = malloc<Int32>();
  final offset = malloc<Float>();
  final env = malloc<Float>(cap);
  final envLen = malloc<Int32>();
  final dur = malloc<Float>();
  try {
    if (fn(p, bpm, key, offset, env, cap, envLen, dur) != 1) return null;
    return TrackStructure(
      bpm: bpm.value,
      key: key.value,
      beatOffset: offset.value,
      durationSec: dur.value,
      env: [for (var i = 0; i < envLen.value; i++) env[i]],
    );
  } finally {
    malloc.free(p);
    malloc.free(bpm);
    malloc.free(key);
    malloc.free(offset);
    malloc.free(env);
    malloc.free(envLen);
    malloc.free(dur);
  }
}

Future<TrackStructure?> analyzeTrackStructureOffUi(String path) async {
  try {
    return await Isolate.run(() => analyzeTrackStructure(path));
  } catch (_) {
    return analyzeTrackStructure(path);
  }
}
