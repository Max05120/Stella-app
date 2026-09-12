#ifndef STELLA_APM_BRIDGE_H_
#define STELLA_APM_BRIDGE_H_

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void* StellaAPMHandle;

StellaAPMHandle StellaAPMCreate(void);
void StellaAPMDestroy(StellaAPMHandle handle);
bool StellaAPMIsReady(StellaAPMHandle handle);

// Processes exactly one 10 ms mono capture frame.
//
// Examples:
//   48 kHz -> 480 samples
//   32 kHz -> 320 samples
//   16 kHz -> 160 samples
//
// Samples are Float32 PCM in the range [-1.0, 1.0].
// Processing happens in-place.
bool StellaAPMProcessCapture(
    StellaAPMHandle handle,
    float* samples,
    int sample_count,
    int sample_rate_hz
);

// Processes exactly one 10 ms mono render frame.
// Kokoro currently runs at 24 kHz -> 240 samples.
bool StellaAPMProcessRender(
    StellaAPMHandle handle,
    const float* samples,
    int sample_count,
    int sample_rate_hz
);

#ifdef __cplusplus
}
#endif

#endif
