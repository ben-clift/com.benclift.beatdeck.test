#pragma once
// Master effects unit: echo, reverb (Freeverb-style) and flanger.
// process() is called from the audio thread only.
#include <algorithm>
#include <cmath>
#include <vector>

#include "biquad.hpp"

namespace fx {

constexpr int kEchoMax = 1 << 18;   // ~2.7 s at 96 kHz
constexpr int kFlangeMax = 4096;

struct Comb {
  std::vector<float> buf;
  int idx = 0;
  float store = 0;
  void init(int n) { buf.assign(std::max(1, n), 0.0f); idx = 0; store = 0; }
  float process(float in, float fb, float damp) {
    const float out = buf[idx];
    store = out * (1.0f - damp) + store * damp;
    buf[idx] = in + store * fb;
    if (++idx >= (int)buf.size()) idx = 0;
    return out;
  }
};

struct Allpass {
  std::vector<float> buf;
  int idx = 0;
  void init(int n) { buf.assign(std::max(1, n), 0.0f); idx = 0; }
  float process(float in) {
    const float b = buf[idx];
    const float out = b - in;
    buf[idx] = in + b * 0.5f;
    if (++idx >= (int)buf.size()) idx = 0;
    return out;
  }
};

struct Unit {
  // Settings written by the UI thread.
  // type: 0 off, 1 echo, 2 reverb, 3 flanger
  int sr = 0;
  std::vector<float> echoL, echoR, flL, flR;
  int echoPos = 0;
  int flPos = 0;
  float lfo = 0;
  static constexpr int kCombs = 8;
  static constexpr int kAll = 4;
  Comb combL[kCombs], combR[kCombs];
  Allpass apL[kAll], apR[kAll];
  float lpL = 0, lpR = 0; // darkening of each echo repeat
  float hpEL = 0, hpER = 0; // low cut inside the echo loop
  float echoD = 0;          // smoothed delay (samples): a tempo change glides like tape
  float lpCoef = 0.5f, hpCoef = 0.02f, echoFb = 0.0f;
  float rvHp = 0;           // keeps bass out of the reverb
  float rvLpL = 0, rvLpR = 0; // reverb tail loses treble faster

  void prepare(int newSr) {
    if (newSr == sr) return;
    sr = newSr;
    echoL.assign(kEchoMax, 0.0f);
    echoR.assign(kEchoMax, 0.0f);
    flL.assign(kFlangeMax, 0.0f);
    flR.assign(kFlangeMax, 0.0f);
    echoPos = flPos = 0;
    echoD = 0;
    const float twoPi = 6.2831853f;
    lpCoef = 1.0f - std::exp(-twoPi * 5000.0f / (float)sr);
    hpCoef = 1.0f - std::exp(-twoPi * 150.0f / (float)sr);
    static const int ct[kCombs] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
    static const int at[kAll] = {556, 441, 341, 225};
    const float k = (float)sr / 44100.0f;
    for (int i = 0; i < kCombs; ++i) {
      combL[i].init((int)(ct[i] * k));
      combR[i].init((int)((ct[i] + 23) * k));
    }
    for (int i = 0; i < kAll; ++i) {
      apL[i].init((int)(at[i] * k));
      apR[i].init((int)((at[i] + 23) * k));
    }
  }

  // timeSec: echo delay (one beat etc.) or flanger rate scale; amount 0..1.
  void process(int type, float amount, float timeSec, float& l, float& r) {
    if (type <= 0 || sr == 0) return;
    const float a = std::max(0.0f, std::min(1.0f, amount));
    if (type == 1) {
      const float target = std::max(2.0f, std::min((float)(kEchoMax - 2), timeSec * sr));
      if (echoD <= 0) echoD = target;
      echoD += (target - echoD) * 0.0006f; // tape-style glide when the time changes
      float rp = (float)echoPos - echoD;
      while (rp < 0) rp += kEchoMax;
      const int i0 = (int)rp % kEchoMax;
      const int i1 = (i0 + 1) % kEchoMax;
      const float fr = rp - std::floor(rp);
      float wl = echoL[i0] * (1.0f - fr) + echoL[i1] * fr;
      float wr = echoR[i0] * (1.0f - fr) + echoR[i1] * fr;
      // Each repeat is darker and thinner than the last, like a tape loop.
      lpL += lpCoef * (wl - lpL);
      lpR += lpCoef * (wr - lpR);
      hpEL += hpCoef * (lpL - hpEL);
      hpER += hpCoef * (lpR - hpER);
      wl = lpL - hpEL;
      wr = lpR - hpER;
      const float efb = (echoFb > 0 ? echoFb : 0.30f + 0.5f * a);
      // ping-pong feedback, soft-clipped so it can never run away
      echoL[echoPos] = l + std::tanh(wr * efb);
      echoR[echoPos] = r + std::tanh(wl * efb);
      if (++echoPos >= kEchoMax) echoPos = 0;
      // equal-power blend: no dip in level at the middle
      l += wl * std::sin(a * 1.5707963f);
      r += wr * std::sin(a * 1.5707963f);
    } else if (type == 2) {
      float in = (l + r) * 0.015f;
      rvHp += 0.04f * (in - rvHp); // about 280 Hz: no bass into the reverb
      in -= rvHp;
      float oL = 0, oR = 0;
      const float fb = 0.80f + 0.12f * a;
      const float damp = 0.5f; // treble dies faster than the body
      for (int i = 0; i < kCombs; ++i) {
        oL += combL[i].process(in, fb, damp);
        oR += combR[i].process(in, fb, damp);
      }
      for (int i = 0; i < kAll; ++i) {
        oL = apL[i].process(oL);
        oR = apR[i].process(oR);
      }
      rvLpL += 0.45f * (oL - rvLpL);
      rvLpR += 0.45f * (oR - rvLpR);
      const float w = std::sin(a * 1.5707963f) * 3.0f;
      l += rvLpL * w;
      r += rvLpR * w;
    } else if (type == 3) {
      const float rate = 0.15f + 0.5f * std::max(0.0f, std::min(4.0f, timeSec));
      lfo += 6.2831853f * rate / (float)sr;
      if (lfo > 6.2831853f) lfo -= 6.2831853f;
      const float dl = (0.0015f + 0.0012f * std::sin(lfo)) * sr;       // samples
      const float dr = (0.0015f + 0.0012f * std::sin(lfo + 1.57f)) * sr;
      auto tap = [&](std::vector<float>& b, float d) {
        float p = (float)flPos - d;
        while (p < 0) p += kFlangeMax;
        const int i0 = (int)p % kFlangeMax;
        const int i1 = (i0 + 1) % kFlangeMax;
        const float f = p - std::floor(p);
        return b[i0] * (1.0f - f) + b[i1] * f;
      };
      const float wl = tap(flL, dl);
      const float wr = tap(flR, dr);
      flL[flPos] = l + wl * 0.6f;
      flR[flPos] = r + wr * 0.6f;
      if (++flPos >= kFlangeMax) flPos = 0;
      l = l * (1.0f - 0.5f * a) + wl * a * 0.7f;
      r = r * (1.0f - 0.5f * a) + wr * a * 0.7f;
    }
  }
};

// Per-deck effect rack. Up to eight effects can be on at once, in this
// order: echo, reverb, flanger, phaser, filter, gate, noise sweep, roll.
struct DeckFx {
  Unit base; // echo, reverb and flanger share the master unit's code
  int sr = 0;
  // phaser
  float phX1[4][2] = {};
  float phY1[4][2] = {};
  float phFb[2] = {};
  float phLfo = 0;
  // filter (low pass whose cutoff drops as the amount rises)
  Biquad fltL, fltR;
  float fltAmount = -1;
  // trance gate
  float gatePhase = 0;
  float gateG = 1;
  // smoothed amount, and the tail that rings on after the effect is switched off
  float sa = -1;
  int tail = 0;
  int lastMask = 0;
  // noise sweep (white noise through a rising high pass)
  Biquad nzL, nzR;
  float nzPhase = 0;
  int nzTick = 0;
  unsigned nzSeed = 22222u;
  // dub echo (3/4 beat, dark, long) and spiral (rising pitch echo)
  Unit dub;
  std::vector<float> spL, spR;
  int spPos = 0;
  float spD = 0;
  // high pass
  Biquad hpL, hpR;
  float hpAmount = -1;
  // vinyl brake
  std::vector<float> brL, brR;
  int brW = 0;
  double brRead = 0;
  float brSpeed = 1;
  bool brActive = false;
  int brFade = 0;
  // bit crusher
  float bcHold[2] = {};
  int bcCount = 0;
  // tape warmth and output protection
  float tapeLp[2] = {};
  float tapeCoef = 0.8f;
  float dcX[2] = {}, dcY[2] = {};
  // roll
  std::vector<float> rollL, rollR;
  int rollHeld = 0;
  int rollRec = 0;
  int rollLen = 0;
  int rollPos = 0;
  bool rollActive = false;

  void idle() { dcX[0] = dcX[1] = dcY[0] = dcY[1] = 0; }

  void prepare(int newSr) {
    if (newSr == sr) return;
    sr = newSr;
    base.prepare(sr);
    rollL.assign(sr, 0.0f);
    rollR.assign(sr, 0.0f);
    dub.prepare(sr);
    dub.lpCoef = 1.0f - std::exp(-6.2831853f * 3200.0f / (float)sr);
    dub.echoFb = 0.62f;
    spL.assign(sr * 2, 0.0f);
    spR.assign(sr * 2, 0.0f);
    brL.assign(sr * 3, 0.0f);
    brR.assign(sr * 3, 0.0f);
    tapeCoef = 1.0f - std::exp(-6.2831853f * 13000.0f / (float)sr);
    hpL.highPass((float)sr, 30.0f, 1.0f);
    hpR.highPass((float)sr, 30.0f, 1.0f);
    hpAmount = -1;
    fltL.lowPass((float)sr, 18000.0f, 1.0f);
    fltR.lowPass((float)sr, 18000.0f, 1.0f);
    nzL.highPass((float)sr, 300.0f, 0.8f);
    nzR.highPass((float)sr, 300.0f, 0.8f);
    fltAmount = -1;
  }

  // mask bit 0 echo, 1 reverb, 2 flanger, 3 phaser, 4 filter, 5 crush,
  // 6 noise sweep, 7 roll. timeSec is the length of one beat.
  void process(int mask, float amount, float timeSec, float& l, float& r) {
    if (sr == 0) return;
    if (sa < 0) sa = amount;
    sa += (amount - sa) * 0.0015f; // no zipper noise when the slider moves
    float a = std::max(0.0f, std::min(1.0f, sa));
    // Echo, reverb, flanger, phaser and filter ring out for a moment after
    // they are switched off, instead of being cut dead.
    const float tailLen = 1.5f * (float)sr;
    if (mask != 0) {
      lastMask = mask;
      tail = (int)tailLen;
    } else if (tail > 0) {
      mask = lastMask & (1 | 2 | 4 | 8 | 16 | 256 | 1024);
      --tail;
      a *= (float)tail / tailLen;
      if (mask == 0) tail = 0;
    }
    if (!(mask & (128 | 4096))) { rollActive = false; rollHeld = 0; }
    if (mask == 0 && !brActive) return;
    const float beat = std::max(0.1f, std::min(2.5f, timeSec));
    if (mask & 1) base.process(1, a, beat, l, r);
    if (mask & 2) base.process(2, a, beat, l, r);
    if (mask & 4) base.process(3, a, beat, l, r);
    if (mask & 8) {
      phLfo += 6.2831853f / (beat * 8.0f * (float)sr);
      if (phLfo > 6.2831853f) phLfo -= 6.2831853f;
      const float fc = 400.0f + 2600.0f * (0.5f + 0.5f * std::sin(phLfo));
      const float t = std::tan(3.14159265f * fc / (float)sr);
      const float coef = (1.0f - t) / (1.0f + t);
      float* ch[2] = {&l, &r};
      for (int c = 0; c < 2; ++c) {
        const float in = *ch[c];
        float x = in + phFb[c] * 0.35f;
        for (int st = 0; st < 4; ++st) {
          const float y = -coef * x + phX1[st][c] + coef * phY1[st][c];
          phX1[st][c] = x;
          phY1[st][c] = y;
          x = y;
        }
        phFb[c] = x;
        *ch[c] = in * (1.0f - 0.5f * a) + x * (0.5f * a);
      }
    }
    if (mask & 16) {
      if (std::fabs(a - fltAmount) > 0.004f) {
        fltAmount = a;
        const float fc = 18000.0f * std::pow(0.01f, a); // 18 kHz down to 180 Hz
        const float f = std::min(fc, 0.45f * (float)sr);
        fltL.lowPass((float)sr, f, 1.0f);
        fltR.lowPass((float)sr, f, 1.0f);
      }
      l = fltL.process(l);
      r = fltR.process(r);
    }
    if (mask & 32) {
      // Trance gate: chops the sound into sixteenths; the amount is how deep.
      gatePhase += 1.0f / (beat * 0.25f * (float)sr);
      if (gatePhase >= 1.0f) gatePhase -= 1.0f;
      const float target = gatePhase < 0.55f ? 1.0f : 1.0f - a;
      gateG += (target - gateG) * 0.02f;
      l *= gateG;
      r *= gateG;
    }
    if (mask & 64) {
      // Sweep rises over four beats, then starts again.
      nzPhase += 1.0f / (beat * 4.0f * (float)sr);
      if (nzPhase >= 1.0f) nzPhase -= 1.0f;
      if (++nzTick >= 32) {
        nzTick = 0;
        const float fc = std::min(300.0f * std::pow(30.0f, nzPhase), 0.45f * (float)sr);
        nzL.highPass((float)sr, fc, 0.8f);
        nzR.highPass((float)sr, fc, 0.8f);
      }
      nzSeed = nzSeed * 1664525u + 1013904223u;
      const float n1 = ((float)(nzSeed >> 8) / 8388608.0f - 1.0f);
      nzSeed = nzSeed * 1664525u + 1013904223u;
      const float n2 = ((float)(nzSeed >> 8) / 8388608.0f - 1.0f);
      const float level = 0.35f * a * (0.3f + 0.7f * nzPhase);
      l += nzL.process(n1) * level;
      r += nzR.process(n2) * level;
    }
    if (mask & (128 | 4096)) {
      if (!rollActive) {
        rollActive = true;
        rollLen = std::max(256, std::min(sr - 1, (int)(beat * 0.25f * (float)sr)));
        rollRec = 0;
        rollPos = 0;
        rollHeld = 0;
      }
      if (rollRec < rollLen) {
        rollL[rollRec] = l;
        rollR[rollRec] = r;
        ++rollRec;
      } else {
        // Beat repeat shortens each beat held (1/4, 1/8, 1/16): a build.
        if ((mask & 4096) && ++rollHeld >= (int)(beat * (float)sr)) {
          rollHeld = 0;
          rollLen = std::max(256, std::max((int)(beat * 0.0625f * (float)sr), rollLen / 2));
          if (rollPos >= rollLen) rollPos = 0;
        }
        const int edge = std::min(rollPos, rollLen - rollPos);
        const float g = std::min(1.0f, (float)edge / 48.0f); // no click at the loop point
        l = rollL[rollPos] * g;
        r = rollR[rollPos] * g;
        if (++rollPos >= rollLen) rollPos = 0;
      }
    }
    if (mask & 256) {
      // High pass: sweeps up from 30 Hz; the first few percent do nothing.
      if (std::fabs(a - hpAmount) > 0.004f) {
        hpAmount = a;
        const float fc = std::min(30.0f * std::pow(200.0f, a), 0.45f * (float)sr);
        hpL.highPass((float)sr, fc, 1.0f);
        hpR.highPass((float)sr, fc, 1.0f);
      }
      if (a > 0.03f) {
        l = hpL.process(l);
        r = hpR.process(r);
      }
    }
    if (mask & 1024) {
      // Dub echo: three-quarter-beat tape echo, dark and long.
      dub.process(1, std::max(a, 0.35f), beat * 0.75f, l, r);
    }
    if (mask & 2048) {
      // Spiral: the echo's delay keeps shrinking, so every repeat climbs in pitch.
      const int n = (int)spL.size();
      if (spD <= 0.0f) spD = std::min((float)(n - 2), beat * 0.5f * (float)sr);
      spD -= 0.22f;
      const float minD = 0.03f * (float)sr;
      float fade = 1.0f;
      if (spD < minD) {
        spD = std::min((float)(n - 2), beat * 0.5f * (float)sr);
        std::fill(spL.begin(), spL.end(), 0.0f);
        std::fill(spR.begin(), spR.end(), 0.0f);
      } else if (spD < minD * 3.0f) {
        fade = (spD - minD) / (minD * 2.0f);
      }
      float rp = (float)spPos - spD;
      while (rp < 0) rp += n;
      const int i0 = (int)rp % n;
      const int i1 = (i0 + 1) % n;
      const float fr = rp - std::floor(rp);
      const float wl = spL[i0] * (1.0f - fr) + spL[i1] * fr;
      const float wr = spR[i0] * (1.0f - fr) + spR[i1] * fr;
      spL[spPos] = l + std::tanh(wl * 0.68f);
      spR[spPos] = r + std::tanh(wr * 0.68f);
      if (++spPos >= n) spPos = 0;
      l += wl * a * 0.8f * fade;
      r += wr * a * 0.8f * fade;
    } else {
      spD = 0.0f;
    }
    if (mask & 8192) {
      // Crusher: fewer samples and fewer bits as the amount rises.
      const int hold = 1 + (int)(a * 14.0f);
      const float bits = 16.0f - a * 10.0f;
      const float step = std::pow(2.0f, 1.0f - bits);
      if (++bcCount >= hold) {
        bcCount = 0;
        bcHold[0] = std::floor(l / step + 0.5f) * step;
        bcHold[1] = std::floor(r / step + 0.5f) * step;
      }
      l = bcHold[0];
      r = bcHold[1];
    }
    if (mask & 16384) {
      // Tape: soft saturation and a little treble loss, level kept steady.
      const float g = 1.0f + a * 3.5f;
      const float norm = std::tanh(g);
      tapeLp[0] += tapeCoef * (std::tanh(l * g) / norm - tapeLp[0]);
      tapeLp[1] += tapeCoef * (std::tanh(r * g) / norm - tapeLp[1]);
      l = tapeLp[0];
      r = tapeLp[1];
    }
    // Vinyl brake: records what is playing, then slows it to a stop; when
    // released it spins back up and fades into the live sound.
    {
      const int n = (int)brL.size();
      const bool want = (mask & 512) != 0;
      brL[brW] = l;
      brR[brW] = r;
      if (want && !brActive) {
        brActive = true;
        brSpeed = 1.0f;
        brRead = (double)brW;
        brFade = 0;
      }
      if (brActive) {
        if (want) {
          brSpeed = std::max(0.0f, brSpeed - 1.0f / (0.7f * (float)sr));
        } else {
          brSpeed = std::min(1.0f, brSpeed + 1.0f / (0.35f * (float)sr));
        }
        double rp = brRead;
        while (rp < 0) rp += n;
        const int i0 = (int)rp % n;
        const int i1 = (i0 + 1) % n;
        const float fr = (float)(rp - std::floor(rp));
        float wl = brL[i0] * (1.0f - fr) + brL[i1] * fr;
        float wr = brR[i0] * (1.0f - fr) + brR[i1] * fr;
        const float quiet = std::min(1.0f, brSpeed * 6.0f); // no hum at a standstill
        wl *= quiet;
        wr *= quiet;
        brRead += brSpeed;
        if (brRead >= n) brRead -= n;
        if (!want && brSpeed >= 1.0f) {
          // Back to full speed: crossfade to the live sound.
          const float k = std::min(1.0f, (float)brFade / 2048.0f);
          l = wl * (1.0f - k) + l * k;
          r = wr * (1.0f - k) + r * k;
          if (++brFade >= 2048) brActive = false;
        } else {
          l = wl;
          r = wr;
        }
      }
      if (++brW >= n) brW = 0;
    }
    // Output protection: no DC offset, and a soft ceiling instead of clipping.
    {
      float* ch[2] = {&l, &r};
      for (int c = 0; c < 2; ++c) {
        const float x = *ch[c];
        const float y = x - dcX[c] + 0.995f * dcY[c];
        dcX[c] = x;
        dcY[c] = y;
        float o = y;
        const float ax = std::fabs(o);
        if (ax > 0.9f) o = (o < 0 ? -1.0f : 1.0f) * (0.9f + 0.1f * std::tanh((ax - 0.9f) / 0.1f));
        *ch[c] = o;
      }
    }
  }
};

}  // namespace fx
