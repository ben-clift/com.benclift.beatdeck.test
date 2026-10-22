#pragma once
// AAC / ALAC in M4A on Apple platforms, through AudioToolbox. Same interface
// as the Android MediaCodec decoder so StreamingDecoder can use either.

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>

#include <cstdint>
#include <cstring>

struct MediaCodecAacDecoder {
  ExtAudioFileRef file = nullptr;
  unsigned channels = 0;
  unsigned sampleRate = 0;
  uint64_t totalFrames = 0;
  uint64_t pcmCursor = 0;

  MediaCodecAacDecoder() = default;
  MediaCodecAacDecoder(const MediaCodecAacDecoder&) = delete;
  MediaCodecAacDecoder& operator=(const MediaCodecAacDecoder&) = delete;
  ~MediaCodecAacDecoder() { close(); }

  void close() {
    if (file) {
      ExtAudioFileDispose(file);
      file = nullptr;
    }
  }

  bool open(const char* path) {
    close();
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(
        nullptr, reinterpret_cast<const UInt8*>(path), (CFIndex)std::strlen(path), false);
    if (!url) return false;
    OSStatus st = ExtAudioFileOpenURL(url, &file);
    CFRelease(url);
    if (st != noErr) {
      file = nullptr;
      return false;
    }
    AudioStreamBasicDescription src{};
    UInt32 sz = sizeof(src);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &sz, &src) != noErr ||
        src.mSampleRate <= 0) {
      close();
      return false;
    }
    sampleRate = (unsigned)src.mSampleRate;
    channels = 2;
    AudioStreamBasicDescription dst{};
    dst.mSampleRate = src.mSampleRate;
    dst.mFormatID = kAudioFormatLinearPCM;
    dst.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    dst.mChannelsPerFrame = 2;
    dst.mBitsPerChannel = 32;
    dst.mBytesPerFrame = 8;
    dst.mFramesPerPacket = 1;
    dst.mBytesPerPacket = 8;
    if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(dst), &dst) != noErr) {
      close();
      return false;
    }
    SInt64 len = 0;
    sz = sizeof(len);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &sz, &len) != noErr || len <= 0) {
      close();
      return false;
    }
    totalFrames = (uint64_t)len;
    pcmCursor = 0;
    return true;
  }

  uint64_t tell() const { return pcmCursor; }

  bool seek(uint64_t frame) {
    if (!file) return false;
    if (frame > totalFrames) frame = totalFrames;
    if (ExtAudioFileSeek(file, (SInt64)frame) != noErr) return false;
    pcmCursor = frame;
    return true;
  }

  // Interleaved stereo float frames; returns how many were read.
  uint64_t readStereo(float* out, uint64_t frames) {
    if (!file || !out || frames == 0) return 0;
    uint64_t got = 0;
    while (got < frames) {
      UInt32 n = (UInt32)(frames - got);
      AudioBufferList abl{};
      abl.mNumberBuffers = 1;
      abl.mBuffers[0].mNumberChannels = 2;
      abl.mBuffers[0].mDataByteSize = n * 8;
      abl.mBuffers[0].mData = out + got * 2;
      if (ExtAudioFileRead(file, &n, &abl) != noErr || n == 0) break;
      got += n;
      pcmCursor += n;
    }
    return got;
  }
};
