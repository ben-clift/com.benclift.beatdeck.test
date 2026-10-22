#pragma once
// A tiny stand-in for the parts of Oboe that the DJ engine uses, built on the
// iOS RemoteIO audio unit. It lets dj_engine.cpp compile unchanged on iPhone.

#include <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <cstdint>
#include <memory>

extern "C" double ios_audio_session_begin(double preferredSampleRate);
extern "C" void ios_audio_session_end(void);

namespace oboe {

enum class Direction { Output, Input };
enum class PerformanceMode { None, LowLatency, PowerSaving };
enum class SharingMode { Exclusive, Shared };
enum class AudioFormat { Invalid, Float, I16 };
enum class Usage { Media };
enum class SpatializationBehavior { Never };
enum class SampleRateConversionQuality { None };
enum class Result { OK, ErrorInternal };
enum class DataCallbackResult { Continue, Stop };

inline const char* convertToText(Result r) { return r == Result::OK ? "OK" : "ErrorInternal"; }
inline const char* convertToText(AudioFormat f) { return f == AudioFormat::Float ? "Float" : "Other"; }

class AudioStream;

class AudioStreamDataCallback {
 public:
  virtual ~AudioStreamDataCallback() = default;
  virtual DataCallbackResult onAudioReady(AudioStream* stream, void* audioData, int32_t numFrames) = 0;
};

class AudioStreamErrorCallback {
 public:
  virtual ~AudioStreamErrorCallback() = default;
  virtual void onErrorAfterClose(AudioStream*, Result) {}
};

class AudioStream {
 public:
  AudioStreamDataCallback* dataCb = nullptr;
  AudioStreamErrorCallback* errCb = nullptr;
  AudioComponentInstance unit = nullptr;
  int32_t sampleRate = 48000;
  int32_t channels = 2;
  bool started = false;

  ~AudioStream() { close(); }

  int32_t getSampleRate() const { return sampleRate; }
  int32_t getChannelCount() const { return channels; }
  AudioFormat getFormat() const { return AudioFormat::Float; }

  Result requestStart() {
    if (!unit) return Result::ErrorInternal;
    if (AudioOutputUnitStart(unit) != noErr) return Result::ErrorInternal;
    started = true;
    return Result::OK;
  }

  Result stop() {
    if (unit && started) AudioOutputUnitStop(unit);
    started = false;
    return Result::OK;
  }

  Result close() {
    stop();
    if (unit) {
      AudioUnitUninitialize(unit);
      AudioComponentInstanceDispose(unit);
      unit = nullptr;
    }
    return Result::OK;
  }

  static OSStatus render(void* ref, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32,
                         UInt32 frames, AudioBufferList* io) {
    auto* self = static_cast<AudioStream*>(ref);
    if (!io || io->mNumberBuffers < 1) return noErr;
    float* out = static_cast<float*>(io->mBuffers[0].mData);
    const int ch = self->channels;
    // The engine expects short callbacks (at most 2048 frames); iOS can ask
    // for 4096 when the screen is locked, so hand it over in slices.
    UInt32 done = 0;
    while (done < frames) {
      const UInt32 n = std::min<UInt32>(frames - done, 1024);
      float* dst = out + (size_t)done * ch;
      if (self->dataCb == nullptr ||
          self->dataCb->onAudioReady(self, dst, (int32_t)n) == DataCallbackResult::Stop) {
        std::fill(dst, out + (size_t)frames * ch, 0.0f);
        break;
      }
      done += n;
    }
    return noErr;
  }
};

class AudioStreamBuilder {
 public:
  AudioStreamBuilder* setDirection(Direction) { return this; }
  AudioStreamBuilder* setPerformanceMode(PerformanceMode) { return this; }
  AudioStreamBuilder* setSharingMode(SharingMode) { return this; }
  AudioStreamBuilder* setFormat(AudioFormat) { return this; }
  AudioStreamBuilder* setSampleRate(int32_t sr) { sampleRate_ = sr; return this; }
  AudioStreamBuilder* setUsage(Usage) { return this; }
  AudioStreamBuilder* setSpatializationBehavior(SpatializationBehavior) { return this; }
  AudioStreamBuilder* setChannelConversionAllowed(bool) { return this; }
  AudioStreamBuilder* setFormatConversionAllowed(bool) { return this; }
  AudioStreamBuilder* setSampleRateConversionQuality(SampleRateConversionQuality) { return this; }
  AudioStreamBuilder* setChannelCount(int32_t ch) { channels_ = ch; return this; }
  AudioStreamBuilder* setDeviceId(int32_t) { return this; }
  AudioStreamBuilder* setDataCallback(AudioStreamDataCallback* cb) { dataCb_ = cb; return this; }
  AudioStreamBuilder* setErrorCallback(AudioStreamErrorCallback* cb) { errCb_ = cb; return this; }

  Result openStream(std::shared_ptr<AudioStream>& out) {
    const double actual = ios_audio_session_begin(sampleRate_ > 0 ? sampleRate_ : 48000);
    auto s = std::make_shared<AudioStream>();
    s->dataCb = dataCb_;
    s->errCb = errCb_;
    s->sampleRate = (int32_t)(actual > 0 ? actual : 48000);
    s->channels = 2;  // the iPhone engine always runs stereo

    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &s->unit) != noErr) return Result::ErrorInternal;

    AudioStreamBasicDescription fmt{};
    fmt.mSampleRate = s->sampleRate;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel = 32;
    fmt.mBytesPerFrame = 8;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = 8;
    if (AudioUnitSetProperty(s->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
                             sizeof(fmt)) != noErr) {
      return Result::ErrorInternal;
    }
    AURenderCallbackStruct cb{};
    cb.inputProc = &AudioStream::render;
    cb.inputProcRefCon = s.get();
    if (AudioUnitSetProperty(s->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                             sizeof(cb)) != noErr) {
      return Result::ErrorInternal;
    }
    if (AudioUnitInitialize(s->unit) != noErr) return Result::ErrorInternal;
    out = s;
    return Result::OK;
  }

 private:
  int32_t sampleRate_ = 48000;
  int32_t channels_ = 2;
  AudioStreamDataCallback* dataCb_ = nullptr;
  AudioStreamErrorCallback* errCb_ = nullptr;
};

}  // namespace oboe
