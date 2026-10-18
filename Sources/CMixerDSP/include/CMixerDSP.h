#ifndef NAHT_MIXER_DSP_H
#define NAHT_MIXER_DSP_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NMDSPState NMDSPState;

// Control-thread helper: disable hardware input streams before IO starts and
// verify HAL accepted the stream-use mask. This never starts a device.
OSStatus nm_configure_input_stream_usage(AudioObjectID device,
                                         AudioDeviceIOProcID _Nonnull ioProc,
                                         const uint32_t * _Nonnull enabledStreams,
                                         uint32_t streamCount);

// Creation/destruction run on the route's control queue, never in an IOProc.
// Source channels are a contiguous range in the aggregate's input channels.
// Hardware input channels preceding the tap are deliberately never read.
NMDSPState * _Nullable nm_dsp_create(
    const uint32_t * _Nonnull inputChannels, uint32_t inputBufferCount,
    const uint32_t * _Nonnull outputChannels, uint32_t outputBufferCount,
    uint32_t sourceChannelOffset, uint32_t sourceChannelCount,
    double sampleRate, float initialGain);
void nm_dsp_destroy(NMDSPState * _Nullable state);

// These operations use lock-free atomics. Caller keeps state alive.
void nm_dsp_set_gain(NMDSPState * _Nonnull state, float gain);
float nm_dsp_peak(const NMDSPState * _Nonnull state);
float nm_dsp_input_peak(const NMDSPState * _Nonnull state);
uint64_t nm_dsp_processed_frames(const NMDSPState * _Nonnull state);
bool nm_dsp_failed(const NMDSPState * _Nonnull state);
void nm_dsp_invalidate(NMDSPState * _Nonnull state);
OSStatus nm_dsp_property_changed(AudioObjectID object, UInt32 count,
                                 const AudioObjectPropertyAddress * _Nonnull addresses,
                                 void * _Nullable context);

// Exposed for deterministic synthetic-buffer tests. No allocation or locks.
void nm_dsp_render(NMDSPState * _Nonnull state,
                   const AudioBufferList * _Nullable input,
                   AudioBufferList * _Nullable output);

OSStatus nm_dsp_io_proc(AudioObjectID device,
                       const AudioTimeStamp * _Nonnull now,
                       const AudioBufferList * _Nonnull input,
                       const AudioTimeStamp * _Nonnull inputTime,
                       AudioBufferList * _Nonnull output,
                       const AudioTimeStamp * _Nonnull outputTime,
                       void * _Nullable context);

#ifdef __cplusplus
}
#endif
#endif
