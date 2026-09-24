#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define BUFFERS 4
#define SAMPLES 480

typedef void (*audio_callback)(void *, int16_t *, uint32_t);
typedef struct {
  AudioQueueRef input, output;
  AudioQueueBufferRef in_buffers[BUFFERS], out_buffers[BUFFERS];
  audio_callback capture, playback;
  void *context;
  atomic_bool recording, playing;
} mux_audio;

static void input_callback(void *context, AudioQueueRef queue,
                           AudioQueueBufferRef buffer,
                           const AudioTimeStamp *time, UInt32 packets,
                           const AudioStreamPacketDescription *descriptions) {
  (void)time;
  (void)packets;
  (void)descriptions;
  mux_audio *audio = context;
  if (!atomic_load(&audio->recording))
    return;
  audio->capture(audio->context, buffer->mAudioData,
                 buffer->mAudioDataByteSize / 2);
  AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static void fill(mux_audio *audio, AudioQueueBufferRef buffer) {
  audio->playback(audio->context, buffer->mAudioData, SAMPLES);
  buffer->mAudioDataByteSize = SAMPLES * 2;
}

static void output_callback(void *context, AudioQueueRef queue,
                            AudioQueueBufferRef buffer) {
  mux_audio *audio = context;
  if (!atomic_load(&audio->playing))
    return;
  fill(audio, buffer);
  AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static OSStatus pin_default(AudioQueueRef queue,
                            AudioObjectPropertySelector selector) {
  AudioObjectPropertyAddress property = {selector,
                                         kAudioObjectPropertyScopeGlobal,
                                         kAudioObjectPropertyElementMain};
  AudioDeviceID device = 0;
  UInt32 size = sizeof(device);
  OSStatus error = AudioObjectGetPropertyData(
      kAudioObjectSystemObject, &property, 0, NULL, &size, &device);
  if (error || !device)
    return error ? error : kAudio_ParamError;
  property.mSelector = kAudioDevicePropertyDeviceUID;
  CFStringRef uid = NULL;
  size = sizeof(uid);
  error = AudioObjectGetPropertyData(device, &property, 0, NULL, &size, &uid);
  if (!error)
    error = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice,
                                  &uid, sizeof(uid));
  if (uid)
    CFRelease(uid);
  return error;
}

void mux_audio_destroy(mux_audio *audio) {
  if (!audio)
    return;
  atomic_store(&audio->recording, 0);
  atomic_store(&audio->playing, 0);
  if (audio->input)
    AudioQueueDispose(audio->input, true);
  if (audio->output)
    AudioQueueDispose(audio->output, true);
  free(audio);
}

void *mux_audio_create(audio_callback capture, audio_callback playback,
                       void *context, int32_t *status) {
  mux_audio *audio = calloc(1, sizeof(*audio));
  if (!audio) {
    *status = -108;
    return NULL;
  }
  atomic_init(&audio->recording, false);
  atomic_init(&audio->playing, false);
  audio->capture = capture;
  audio->playback = playback;
  audio->context = context;
  AudioStreamBasicDescription format = {
      .mSampleRate = 48000,
      .mFormatID = kAudioFormatLinearPCM,
      .mFormatFlags =
          kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      .mBytesPerPacket = 2,
      .mFramesPerPacket = 1,
      .mBytesPerFrame = 2,
      .mChannelsPerFrame = 1,
      .mBitsPerChannel = 16,
  };
  *status = AudioQueueNewInput(&format, input_callback, audio, NULL, NULL, 0,
                               &audio->input);
  if (*status)
    goto failed;
  *status = AudioQueueNewOutput(&format, output_callback, audio, NULL, NULL, 0,
                                &audio->output);
  if (*status)
    goto failed;
  *status = pin_default(audio->input, kAudioHardwarePropertyDefaultInputDevice);
  if (*status)
    goto failed;
  *status =
      pin_default(audio->output, kAudioHardwarePropertyDefaultOutputDevice);
  if (*status)
    goto failed;
  for (unsigned i = 0; i < BUFFERS; i++) {
    *status = AudioQueueAllocateBuffer(audio->input, SAMPLES * 2,
                                       &audio->in_buffers[i]);
    if (*status)
      goto failed;
    *status = AudioQueueAllocateBuffer(audio->output, SAMPLES * 2,
                                       &audio->out_buffers[i]);
    if (*status)
      goto failed;
  }
  return audio;
failed:
  mux_audio_destroy(audio);
  return NULL;
}

int32_t mux_audio_state(mux_audio *audio, int capture, int playback) {
  OSStatus error = noErr;
  if (!!capture != atomic_load(&audio->recording)) {
    atomic_store(&audio->recording, !!capture);
    if (capture) {
      for (unsigned i = 0; i < BUFFERS; i++) {
        error = AudioQueueEnqueueBuffer(audio->input, audio->in_buffers[i], 0,
                                        NULL);
        if (error)
          return error;
      }
      error = AudioQueueStart(audio->input, NULL);
    } else {
      error = AudioQueueStop(audio->input, true);
      if (!error)
        error = AudioQueueReset(audio->input);
    }
    if (error)
      return error;
  }
  if (!!playback != atomic_load(&audio->playing)) {
    atomic_store(&audio->playing, !!playback);
    if (playback) {
      for (unsigned i = 0; i < BUFFERS; i++) {
        fill(audio, audio->out_buffers[i]);
        error = AudioQueueEnqueueBuffer(audio->output, audio->out_buffers[i], 0,
                                        NULL);
        if (error)
          return error;
      }
      error = AudioQueueStart(audio->output, NULL);
    } else {
      error = AudioQueueStop(audio->output, true);
      if (!error)
        error = AudioQueueReset(audio->output);
    }
  }
  return error;
}
