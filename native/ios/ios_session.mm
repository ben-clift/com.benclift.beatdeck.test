// Audio session set-up for iPhone: play music (also with the screen locked and
// the silent switch on), low latency, and report the real sample rate.
#import <AVFoundation/AVFoundation.h>

extern "C" double ios_audio_session_begin(double preferredSampleRate) {
  AVAudioSession* s = [AVAudioSession sharedInstance];
  NSError* err = nil;
  [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&err];
  [s setPreferredSampleRate:preferredSampleRate error:nil];
  [s setPreferredIOBufferDuration:0.01 error:nil];
  [s setActive:YES error:&err];
  return s.sampleRate;
}

extern "C" void ios_audio_session_end(void) {
  [[AVAudioSession sharedInstance] setActive:NO error:nil];
}
