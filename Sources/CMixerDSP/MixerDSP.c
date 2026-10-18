#include "CMixerDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define NM_MAX_BUFFERS 32

OSStatus nm_configure_input_stream_usage(AudioObjectID device, AudioDeviceIOProcID ioProc,
                                         const uint32_t *enabledStreams, uint32_t streamCount) {
    if (!ioProc || !enabledStreams || streamCount == 0 || streamCount > NM_MAX_BUFFERS)
        return kAudioHardwareIllegalOperationError;
    size_t bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + streamCount * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)ioProc;
    usage->mNumberStreams = streamCount;
    memcpy(usage->mStreamIsOn, enabledStreams, streamCount * sizeof(UInt32));
    AudioObjectPropertyAddress address = { kAudioDevicePropertyIOProcStreamUsage,
                                           kAudioObjectPropertyScopeInput,
                                           kAudioObjectPropertyElementMain };
    OSStatus result = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)bytes, usage);
    if (result == noErr) {
        UInt32 returnedBytes = (UInt32)bytes;
        // HAL requires mIOProc to be populated for a read as well.
        result = AudioObjectGetPropertyData(device, &address, 0, NULL, &returnedBytes, usage);
        if (result == noErr) {
            if (returnedBytes != bytes || usage->mNumberStreams != streamCount) {
                result = kAudioHardwareUnsupportedOperationError;
            } else {
                for (uint32_t i = 0; i < streamCount; ++i) {
                    if (!!usage->mStreamIsOn[i] != !!enabledStreams[i]) {
                        result = kAudioHardwareUnsupportedOperationError;
                        break;
                    }
                }
            }
        }
    }
    free(usage);
    return result;
}

typedef struct {
    uint32_t buffer;
    uint32_t channel;
    uint32_t stride;
} NMChannel;

struct NMDSPState {
    _Atomic(float) targetGain;
    _Atomic(float) peak;
    _Atomic(float) inputPeak;
    _Atomic(uint64_t) processedFrames;
    _Atomic(bool) failed;
    uint32_t inputBufferCount;
    uint32_t outputBufferCount;
    uint32_t inputChannels[NM_MAX_BUFFERS];
    uint32_t outputChannels[NM_MAX_BUFFERS];
    uint32_t sourceCount;
    uint32_t destinationCount;
    NMChannel source[2];
    NMChannel destination[2];
    uint32_t rampLength;
    uint32_t rampRemaining;
    float currentGain;
    float rampTarget;
    float rampStep;
};

static float safe_gain(float value) {
    if (!isfinite(value) || value <= 0) return 0;
    return value >= 1 ? 1 : value;
}

static bool locate_channel(const uint32_t *counts, uint32_t count,
                           uint32_t index, NMChannel *location) {
    for (uint32_t i = 0; i < count; ++i) {
        if (index < counts[i]) {
            *location = (NMChannel){i, index, counts[i]};
            return true;
        }
        index -= counts[i];
    }
    return false;
}

NMDSPState *nm_dsp_create(const uint32_t *inputChannels, uint32_t inputBufferCount,
                         const uint32_t *outputChannels, uint32_t outputBufferCount,
                         uint32_t sourceChannelOffset, uint32_t sourceChannelCount,
                         double sampleRate, float initialGain) {
    if (!inputChannels || !outputChannels || inputBufferCount == 0 ||
        outputBufferCount == 0 || inputBufferCount > NM_MAX_BUFFERS ||
        outputBufferCount > NM_MAX_BUFFERS || sourceChannelCount == 0 ||
        sourceChannelCount > 2 || !isfinite(sampleRate) ||
        sampleRate < 8000 || sampleRate > 384000) return NULL;

    uint64_t totalInput = 0, totalOutput = 0;
    for (uint32_t i = 0; i < inputBufferCount; ++i) {
        if (inputChannels[i] == 0 || inputChannels[i] > 64) return NULL;
        totalInput += inputChannels[i];
    }
    for (uint32_t i = 0; i < outputBufferCount; ++i) {
        if (outputChannels[i] == 0 || outputChannels[i] > 2) return NULL;
        totalOutput += outputChannels[i];
    }
    // The tap must be the complete trailing input range. Reject any ambiguity.
    if ((uint64_t)sourceChannelOffset + sourceChannelCount != totalInput ||
        totalOutput != sourceChannelCount) return NULL;

    NMDSPState *state = calloc(1, sizeof(NMDSPState));
    if (!state) return NULL;
    atomic_init(&state->targetGain, safe_gain(initialGain));
    atomic_init(&state->peak, 0);
    atomic_init(&state->inputPeak, 0);
    atomic_init(&state->processedFrames, 0);
    atomic_init(&state->failed, false);
    if (!atomic_is_lock_free(&state->targetGain) ||
        !atomic_is_lock_free(&state->peak) || !atomic_is_lock_free(&state->inputPeak) ||
        !atomic_is_lock_free(&state->processedFrames) || !atomic_is_lock_free(&state->failed)) {
        free(state);
        return NULL;
    }
    state->inputBufferCount = inputBufferCount;
    state->outputBufferCount = outputBufferCount;
    memcpy(state->inputChannels, inputChannels, inputBufferCount * sizeof(uint32_t));
    memcpy(state->outputChannels, outputChannels, outputBufferCount * sizeof(uint32_t));
    state->sourceCount = sourceChannelCount;
    state->destinationCount = (uint32_t)totalOutput;
    for (uint32_t i = 0; i < sourceChannelCount; ++i) {
        if (!locate_channel(inputChannels, inputBufferCount, sourceChannelOffset + i, &state->source[i]) ||
            !locate_channel(outputChannels, outputBufferCount, i, &state->destination[i])) {
            free(state);
            return NULL;
        }
    }
    state->rampLength = (uint32_t)(sampleRate * 0.010 + 0.5);
    state->currentGain = state->rampTarget = safe_gain(initialGain);
    return state;
}

void nm_dsp_destroy(NMDSPState *state) { free(state); }
void nm_dsp_set_gain(NMDSPState *state, float gain) {
    atomic_store_explicit(&state->targetGain, safe_gain(gain), memory_order_relaxed);
}
float nm_dsp_peak(const NMDSPState *state) {
    return atomic_load_explicit(&state->peak, memory_order_relaxed);
}
float nm_dsp_input_peak(const NMDSPState *state) {
    return atomic_load_explicit(&state->inputPeak, memory_order_relaxed);
}
uint64_t nm_dsp_processed_frames(const NMDSPState *state) {
    return atomic_load_explicit(&state->processedFrames, memory_order_relaxed);
}
bool nm_dsp_failed(const NMDSPState *state) {
    return atomic_load_explicit(&state->failed, memory_order_relaxed);
}

static void fail_render(NMDSPState *state) {
    atomic_store_explicit(&state->failed, true, memory_order_relaxed);
    atomic_store_explicit(&state->peak, 0, memory_order_relaxed);
    atomic_store_explicit(&state->inputPeak, 0, memory_order_relaxed);
}

void nm_dsp_invalidate(NMDSPState *state) { fail_render(state); }

OSStatus nm_dsp_property_changed(AudioObjectID object, UInt32 count,
                                 const AudioObjectPropertyAddress *addresses, void *context) {
    (void)object; (void)count; (void)addresses;
    if (context) fail_render(context);
    return noErr;
}

void nm_dsp_render(NMDSPState *state, const AudioBufferList *input, AudioBufferList *output) {
    // Always clear every destination, even if the device changed its layout.
    if (output) {
        for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
            if (output->mBuffers[i].mData)
                memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
        }
    }
    if (nm_dsp_failed(state)) return;
    if (!input || !output || input->mNumberBuffers != state->inputBufferCount ||
        output->mNumberBuffers != state->outputBufferCount) {
        fail_render(state);
        return;
    }
    for (uint32_t i = 0; i < input->mNumberBuffers; ++i) {
        if (input->mBuffers[i].mNumberChannels != state->inputChannels[i]) {
            fail_render(state);
            return;
        }
    }

    uint32_t frames = 0;
    for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
        const AudioBuffer *buffer = &output->mBuffers[i];
        uint32_t frameBytes = state->outputChannels[i] * sizeof(float);
        if (buffer->mNumberChannels != state->outputChannels[i] ||
            buffer->mDataByteSize % frameBytes != 0 ||
            (!buffer->mData && buffer->mDataByteSize != 0)) {
            fail_render(state);
            return;
        }
        uint32_t bufferFrames = buffer->mDataByteSize / frameBytes;
        if (i == 0) frames = bufferFrames;
        else if (bufferFrames != frames) { fail_render(state); return; }
    }
    for (uint32_t i = 0; i < state->sourceCount; ++i) {
        NMChannel channel = state->source[i];
        const AudioBuffer *buffer = &input->mBuffers[channel.buffer];
        uint32_t frameBytes = channel.stride * sizeof(float);
        if (buffer->mDataByteSize % frameBytes != 0 ||
            buffer->mDataByteSize / frameBytes != frames ||
            (!buffer->mData && frames != 0)) {
            fail_render(state);
            return;
        }
    }

    float target = atomic_load_explicit(&state->targetGain, memory_order_relaxed);
    if (target != state->rampTarget) {
        state->rampTarget = target;
        state->rampRemaining = state->rampLength;
        state->rampStep = (target - state->currentGain) / (float)state->rampLength;
    }
    float peak = 0, inputPeak = 0;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        if (state->rampRemaining != 0) {
            state->currentGain += state->rampStep;
            if (--state->rampRemaining == 0) state->currentGain = state->rampTarget;
        }
        for (uint32_t channelIndex = 0; channelIndex < state->destinationCount; ++channelIndex) {
            NMChannel source = state->source[channelIndex];
            NMChannel destination = state->destination[channelIndex];
            const float *sourceData = input->mBuffers[source.buffer].mData;
            float *destinationData = output->mBuffers[destination.buffer].mData;
            float sample = sourceData[(size_t)frame * source.stride + source.channel];
            if (!isfinite(sample)) sample = 0;
            float sourceMagnitude = fabsf(sample);
            if (sourceMagnitude > inputPeak) inputPeak = sourceMagnitude;
            float result = sample * safe_gain(state->currentGain);
            if (result > 1) result = 1;
            if (result < -1) result = -1;
            destinationData[(size_t)frame * destination.stride + destination.channel] = result;
            float magnitude = fabsf(result);
            if (magnitude > peak) peak = magnitude;
        }
    }
    atomic_store_explicit(&state->peak, peak, memory_order_relaxed);
    atomic_store_explicit(&state->inputPeak, inputPeak, memory_order_relaxed);
    atomic_fetch_add_explicit(&state->processedFrames, (uint64_t)frames, memory_order_relaxed);
}

OSStatus nm_dsp_io_proc(AudioObjectID device, const AudioTimeStamp *now,
                       const AudioBufferList *input, const AudioTimeStamp *inputTime,
                       AudioBufferList *output, const AudioTimeStamp *outputTime,
                       void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    if (context) nm_dsp_render(context, input, output);
    return noErr;
}
