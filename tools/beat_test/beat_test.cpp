// Host test for Setflow's beat grid: synthetic 4/4 tracks with a known tempo
// and first-beat position, run through the engine's own analyzeTrack, and the
// detected tempo and beat phase compared with the truth.
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>
#include "analyze.hpp"

struct Case { const char* name; double bpm; double firstBeat; double swing; double drift; bool hatsLoud; int style; };

static std::vector<float> render(const Case& c, double sr, double dur, std::mt19937& rng) {
  const int n = (int)(sr * dur);
  std::vector<float> x((size_t)n * 2, 0.0f);
  std::normal_distribution<float> nz(0.0f, 1.0f);
  auto add = [&](double t, int kind) {
    int s0 = (int)(t * sr);
    if (s0 < 0) return;
    int len = kind == 0 ? (int)(0.22 * sr) : kind == 1 ? (int)(0.06 * sr) : (int)(0.12 * sr);
    for (int i = 0; i < len && s0 + i < n; ++i) {
      double tt = i / sr;
      float v;
      if (kind == 0) { double f = 50 + 90 * std::exp(-tt * 30); v = (float)(std::sin(2 * M_PI * f * tt) * std::exp(-tt * 14)); }
      else if (kind == 1) { v = 0.35f * nz(rng) * (float)std::exp(-tt * 70); }
      else { v = 0.5f * (float)std::sin(2 * M_PI * 220 * tt) * (float)std::exp(-tt * 12) + 0.15f * nz(rng) * (float)std::exp(-tt * 25); }
      x[(size_t)(s0 + i) * 2] += v; x[(size_t)(s0 + i) * 2 + 1] += v;
    }
  };
  const double beat0 = 60.0 / c.bpm;
  if (c.style == 3) {
    // Drum and bass: kick on 1 and the "and" of 3, snare on 2 and 4, 8th hats.
    for (int bar = 0;; ++bar) {
      double t0 = c.firstBeat + bar * 4 * beat0;
      if (t0 >= dur) break;
      add(t0, 0); add(t0 + 2.5 * beat0, 0);
      add(t0 + 1 * beat0, 2); add(t0 + 3 * beat0, 2);
      for (int h = 0; h < 8; ++h) add(t0 + h * 0.5 * beat0, 1);
    }
    return x;
  }
  if (c.style == 4) {
    // Boom bap at 88: kick on 1 and 3, snare on 2 and 4, 8th hats.
    for (int bar = 0;; ++bar) {
      double t0 = c.firstBeat + bar * 4 * beat0;
      if (t0 >= dur) break;
      add(t0, 0); add(t0 + 2 * beat0, 0);
      add(t0 + 1 * beat0, 2); add(t0 + 3 * beat0, 2);
      for (int h = 0; h < 8; ++h) add(t0 + h * 0.5 * beat0, 1);
    }
    return x;
  }
  for (int b = 0;; ++b) {
    double t = c.firstBeat + b * beat0 * (1.0 + c.drift);
    if (t >= dur) break;
    if (c.style == 2 && b % 2 == 1) { /* breakbeat: skip some kicks */ } else add(t, 0);
    double off = t + beat0 * (0.5 + c.swing * 0.5);
    add(off, 1);
    if (c.hatsLoud) { add(off, 1); add(t + beat0 * 0.25, 1); }
    if (c.style == 1 && b % 4 == 2) add(t + beat0 * 0.5, 2); // bass stab on the off-beat
  }
  return x;
}

int main() {
  const double sr = 22050.0;
  std::mt19937 rng(7);
  Case cases[] = {
    {"house 122", 122, 0.37, 0.0, 0.0, false, 0},
    {"house 124 loud hats", 124, 0.12, 0.0, 0.0, true, 0},
    {"techno 132", 132, 0.52, 0.0, 0.0, false, 1},
    {"techno 138 offbeat bass", 138, 0.21, 0.0, 0.0, true, 1},
    {"dnb 174 four-on-floor", 174, 0.30, 0.0, 0.0, false, 0},
    {"dnb 174 breakbeat", 174, 0.30, 0.0, 0.0, false, 3},
    {"dnb 170 breakbeat", 170, 0.17, 0.0, 0.0, false, 3},
    {"hiphop 88 boom bap", 88, 0.40, 0.0, 0.0, false, 4},
    {"hiphop 92", 92, 0.45, 0.2, 0.0, false, 0},
    {"electro 128 swing", 128, 0.08, 0.3, 0.0, false, 1},
    {"disco 118", 118, 0.60, 0.0, 0.0, true, 0},
    {"slight drift 126", 126, 0.25, 0.0, 0.002, false, 0},
    {"broken kicks 130", 130, 0.33, 0.0, 0.0, false, 2},
  };
  int pass = 0, total = 0;
  std::printf("%-26s %8s %8s %9s %9s  %s\n", "case", "true", "found", "bpm err%", "phase ms", "verdict");
  for (auto& c : cases) {
    auto pcm = render(c, sr, 60.0, rng);
    AnalysisResult r = analyzeTrack(pcm.data(), (int)(pcm.size() / 2), 2, (float)sr);
    double period = 60.0 / c.bpm;
    // Octave-equivalent tempo (half/double) counts as the right grid.
    double ratio = r.bpm / c.bpm;
    double bpmErr = 1e9;
    bpmErr = std::fabs(r.bpm - c.bpm) / c.bpm * 100.0;
    // Phase: distance of the detected beat grid from the true one, in ms.
    double fb = r.beats.empty() ? r.beatOffsetSec : r.beats[0];
    double d = std::fmod(fb - c.firstBeat, period);
    if (d < 0) d += period;
    if (d > period / 2) d -= period;
    double phaseMs = std::fabs(d) * 1000.0;
    bool ok = bpmErr < 0.3 && phaseMs <= 15.0;
    pass += ok; total++;
    std::printf("%-26s %8.2f %8.2f %9.3f %9.1f  %s\n", c.name, c.bpm, r.bpm, bpmErr, phaseMs, ok ? "PASS" : "FAIL");
    (void)ratio;
  }
  std::printf("\n%d of %d pass (tempo within 0.3%%, first beat within 15 ms)\n", pass, total);
  return pass == total ? 0 : 1;
}
