#pragma once

// Queen Mary gives a solid tempo but its phase follows whatever onset is
// strongest, which on a lot of house/techno is the offbeat hat, not the kick.
// Once the period is known, the phase is better decided by the audio: pick the
// offset whose grid lines collect the most low-band onset energy.

#include <algorithm>
#include <cmath>
#include <vector>

namespace grid_phase {

// ~2.5 ms per block, band-limited to roughly the kick range.
struct KickEnvelope {
  std::vector<float> energy;
  std::vector<float> onset; // positive energy rise
  double blockSec = 0.0;

  int index(double t) const {
    if (blockSec <= 0.0) {
      return -1;
    }
    const int i = (int)std::lround(t / blockSec);
    return (i >= 0 && i < (int)energy.size()) ? i : -1;
  }
};

inline KickEnvelope buildKickEnvelope(const float* pcm, int frames, int channels,
                                      double sampleRate) {
  KickEnvelope env;
  if (!pcm || frames <= 0 || channels < 1 || sampleRate <= 0.0) {
    return env;
  }
  // Boxcar decimation doubles as the low-pass and keeps the envelope
  // symmetric, so peaks stay where the transient actually is.
  const int group = std::max(1, (int)std::lround(sampleRate / 400.0));
  const int blocks = frames / group;
  if (blocks < 4) {
    return env;
  }
  env.blockSec = (double)group / sampleRate;
  env.energy.resize((size_t)blocks);
  for (int b = 0; b < blocks; ++b) {
    double acc = 0.0;
    const int start = b * group;
    for (int i = start; i < start + group; ++i) {
      const float* s = pcm + (size_t)i * (size_t)channels;
      acc += channels == 1 ? (double)s[0] : 0.5 * ((double)s[0] + (double)s[1]);
    }
    const double m = acc / (double)group;
    env.energy[(size_t)b] = (float)(m * m);
  }
  env.onset.assign((size_t)blocks, 0.0f);
  for (int b = 1; b < blocks; ++b) {
    const float rise = env.energy[(size_t)b] - env.energy[(size_t)b - 1];
    env.onset[(size_t)b] = rise > 0.0f ? rise : 0.0f;
  }
  return env;
}

// Offset in [0, periodSec) whose grid lines land on the most onset energy.
// Returns a negative value when the envelope carries no usable signal.
inline double bestPhase(const KickEnvelope& env, double periodSec, double durationSec,
                        double* meanScoreOut = nullptr) {
  if (env.onset.empty() || periodSec <= 0.0 || durationSec <= periodSec) {
    return -1.0;
  }
  const int candidates = std::max(1, (int)std::lround(periodSec / env.blockSec));
  const int lines = (int)(durationSec / periodSec);
  if (lines < 4) {
    return -1.0;
  }
  double bestScore = -1.0;
  double best = -1.0;
  for (int c = 0; c < candidates; ++c) {
    const double offset = c * env.blockSec;
    double score = 0.0;
    for (int k = 0; k < lines; ++k) {
      const int i = env.index(offset + (double)k * periodSec);
      if (i < 0) {
        continue;
      }
      // One block either side, so a kick a hair off the line still counts.
      score += env.onset[(size_t)i];
      if (i > 0) {
        score += 0.5 * env.onset[(size_t)i - 1];
      }
      if (i + 1 < (int)env.onset.size()) {
        score += 0.5 * env.onset[(size_t)i + 1];
      }
    }
    if (score > bestScore) {
      bestScore = score;
      best = offset;
    }
  }
  if (meanScoreOut) {
    *meanScoreOut = bestScore > 0.0 ? bestScore / (double)lines : 0.0;
  }
  return bestScore > 0.0 ? best : -1.0;
}

// Queen Mary sometimes reports half, double or a triplet-related tempo (drum
// and bass at 87 or 116 instead of 174). Try the related tempos and keep the
// fastest one whose grid still lands on as much low-end energy per line as the
// best candidate, so a true half-time groove (boom bap at 88) is not doubled.
// A faster tempo wins only if its grid still collects this share of the best
// per-line energy (0.45 doubled boom bap, 0.6 is still safe on the test set).
inline constexpr double kRefineRatio = 0.55;
inline double refineTempo(const KickEnvelope& env, double bpm, double durationSec) {
  if (env.onset.empty() || bpm <= 0.0) {
    return bpm;
  }
  struct Cand { double bpm; double mean; };
  std::vector<Cand> cands;
  // Triplet-related readings only matter around 116 (174 / 1.5); anywhere
  // else they would turn ordinary tempos into odd ones.
  std::vector<double> ratios = {0.5, 1.0, 2.0};
  if (bpm >= 105.0 && bpm <= 125.0) {
    ratios.push_back(1.5);
  }
  for (double k : ratios) {
    const double t = bpm * k;
    if (t < 85.0 || t > 180.0) {
      continue;
    }
    double mean = 0.0;
    if (bestPhase(env, 60.0 / t, durationSec, &mean) < 0.0) {
      continue;
    }
    cands.push_back({t, mean});
  }
  if (cands.empty()) {
    return bpm;
  }
  double top = 0.0;
  for (const auto& c : cands) {
    top = std::max(top, c.mean);
  }
  double pick = bpm;
  double pickBpm = -1.0;
  for (const auto& c : cands) {
    if (c.mean >= kRefineRatio * top && c.bpm > pickBpm) {
      pickBpm = c.bpm;
      pick = c.bpm;
    }
  }
  return pick;
}

// Phrase 0 goes on the first grid line where the track is actually audible.
// Anything cleverer guesses at musical structure and lands on beat 2 or 3,
// which is worse than a predictable start the user can nudge.
inline double firstAudibleLine(const float* pcm, int frames, int channels, double sampleRate,
                               double phaseSec, double periodSec) {
  if (!pcm || frames <= 0 || channels < 1 || sampleRate <= 0.0 || periodSec <= 0.0) {
    return phaseSec;
  }
  const int block = std::max(1, (int)std::lround(sampleRate * 0.02));
  const int blocks = frames / block;
  if (blocks < 8) {
    return phaseSec;
  }
  std::vector<float> rms((size_t)blocks);
  for (int b = 0; b < blocks; ++b) {
    double acc = 0.0;
    const int start = b * block;
    for (int i = start; i < start + block; ++i) {
      const float* s = pcm + (size_t)i * (size_t)channels;
      const double m = channels == 1 ? (double)s[0] : 0.5 * ((double)s[0] + (double)s[1]);
      acc += m * m;
    }
    rms[(size_t)b] = (float)std::sqrt(acc / (double)block);
  }
  std::vector<float> sorted = rms;
  std::nth_element(sorted.begin(), sorted.begin() + (std::ptrdiff_t)(sorted.size() / 2),
                   sorted.end());
  const float thresh = sorted[sorted.size() / 2] * 0.02f;
  if (!(thresh > 0.0f)) {
    return phaseSec;
  }
  int firstLoud = -1;
  for (int b = 0; b + 2 < blocks; ++b) {
    if (rms[(size_t)b] >= thresh && rms[(size_t)b + 1] >= thresh && rms[(size_t)b + 2] >= thresh) {
      firstLoud = b;
      break;
    }
  }
  if (firstLoud <= 0) {
    return phaseSec;
  }
  // Half a block of slack so a beat that opens the track is not skipped.
  const double startSec = (double)firstLoud * ((double)block / sampleRate) - 0.01;
  const double k = std::ceil((startSec - phaseSec) / periodSec);
  return phaseSec + std::max(0.0, k) * periodSec;
}

} // namespace grid_phase
