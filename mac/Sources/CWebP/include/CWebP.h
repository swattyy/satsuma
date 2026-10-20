// Satsuma's small interface to the vendored libwebp, so Swift doesn't handle libwebp's structs directly.
// Pixels are 8-bit RGBA with straight (not premultiplied) alpha.

#ifndef SATSUMA_CWEBP_H
#define SATSUMA_CWEBP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Encodes one picture. quality is 0 to 100; with lossless set, quality is ignored and every pixel is kept.
// Returns the size of the WebP data and points *output at it (release it with SatsumaWebPFree), or returns 0.
size_t SatsumaWebPEncode(const uint8_t* rgba, int width, int height, int stride, float quality, int lossless,
                         uint8_t** output);

// Animated WebP. Every frame covers the whole canvas; timestamps are milliseconds from the start.
// loopCount 0 loops forever.
typedef struct SatsumaWebPAnim SatsumaWebPAnim;

SatsumaWebPAnim* SatsumaWebPAnimNew(int width, int height, float quality, int loopCount);
int SatsumaWebPAnimAdd(SatsumaWebPAnim* anim, const uint8_t* rgba, int stride, int timestampMs);
// endTimestampMs is when the last frame stops showing. Returns the size like SatsumaWebPEncode.
size_t SatsumaWebPAnimFinish(SatsumaWebPAnim* anim, int endTimestampMs, uint8_t** output);
void SatsumaWebPAnimDelete(SatsumaWebPAnim* anim);

void SatsumaWebPFree(void* ptr);

// libwebp's encoder version as 0xMMmmpp, for example 0x010600 for 1.6.0.
int SatsumaWebPEncoderVersion(void);

#ifdef __cplusplus
}
#endif

#endif  // SATSUMA_CWEBP_H
