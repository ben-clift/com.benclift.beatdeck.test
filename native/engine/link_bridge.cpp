// Ableton Link bridge (tempo sync with other apps and phones on the same Wi-Fi).
//
// Link is GPL v2 or later (third_party/ableton-link), which fits this app's
// GPL v3 or later licence. Everything here is called from the Dart UI isolate,
// never from the audio thread, so the app-thread Link API is the right one.
// While Link is switched off nothing is created and nothing touches the network.

#include <ableton/Link.hpp>

#include <memory>
#include <mutex>

namespace {
std::mutex g_mutex;
std::unique_ptr<ableton::Link> g_link;
bool g_on = false;
}  // namespace

extern "C" {

/** 1 = Link is now on, 0 = off (or it could not start). */
int link_enable(int on) {
  std::lock_guard<std::mutex> lock(g_mutex);
  try {
    if (on) {
      if (!g_link) g_link = std::make_unique<ableton::Link>(120.0);
      g_link->enable(true);
      g_on = true;
      return 1;
    }
    if (g_link) g_link->enable(false);
  } catch (...) {
    // A network problem must never crash the app.
  }
  g_on = false;
  return 0;
}

int link_is_enabled(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_on ? 1 : 0;
}

/** Number of other Link apps in the session (0 when off). */
int link_peers(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_on || !g_link) return 0;
  try {
    return static_cast<int>(g_link->numPeers());
  } catch (...) {
    return 0;
  }
}

/** The session tempo in BPM, or 0 when Link is off. */
double link_tempo(void) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_on || !g_link) return 0.0;
  try {
    return g_link->captureAppSessionState().tempo();
  } catch (...) {
    return 0.0;
  }
}

/** Proposes a new session tempo to everyone. */
void link_set_tempo(double bpm) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_on || !g_link || !(bpm >= 20.0 && bpm <= 999.0)) return;
  try {
    auto state = g_link->captureAppSessionState();
    state.setTempo(bpm, g_link->clock().micros());
    g_link->commitAppSessionState(state);
  } catch (...) {
  }
}

/** Where we are in the bar, 0 up to (not including) quantum beats. 0 when off. */
double link_phase(double quantum) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (!g_on || !g_link || !(quantum > 0.0)) return 0.0;
  try {
    auto state = g_link->captureAppSessionState();
    return state.phaseAtTime(g_link->clock().micros(), quantum);
  } catch (...) {
    return 0.0;
  }
}

}  // extern "C"
