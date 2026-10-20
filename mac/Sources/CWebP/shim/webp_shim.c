// Satsuma's wrapper around libwebp's advanced encoding API. See include/CWebP.h.

#include "../include/CWebP.h"

#include <stdlib.h>

#include "src/webp/encode.h"
#include "src/webp/mux.h"

struct SatsumaWebPAnim {
  WebPAnimEncoder* encoder;
  WebPConfig config;
  int width;
  int height;
};

static int Configure(WebPConfig* config, float quality, int lossless) {
  if (!WebPConfigInit(config)) return 0;
  if (lossless) {
    // Like Skia's WebP encoder at quality 100 (the Windows app): lossless at the default effort.
    config->lossless = 1;
    config->quality = 75;
  } else {
    config->quality = quality < 0 ? 0 : quality > 100 ? 100 : quality;
  }
  config->method = 4;
  return WebPValidateConfig(config);
}

// Copies the pixels into a picture. On success the caller frees it with WebPPictureFree.
static int Import(WebPPicture* pic, const uint8_t* rgba, int width, int height, int stride) {
  if (!WebPPictureInit(pic)) return 0;
  pic->use_argb = 1;  // the encoder converts to YUV itself for lossy output
  pic->width = width;
  pic->height = height;
  if (!WebPPictureImportRGBA(pic, rgba, stride)) {
    WebPPictureFree(pic);
    return 0;
  }
  return 1;
}

size_t SatsumaWebPEncode(const uint8_t* rgba, int width, int height, int stride, float quality, int lossless,
                         uint8_t** output) {
  WebPConfig config;
  WebPPicture pic;
  WebPMemoryWriter writer;
  *output = NULL;
  if (!Configure(&config, quality, lossless)) return 0;
  if (!Import(&pic, rgba, width, height, stride)) return 0;
  WebPMemoryWriterInit(&writer);
  pic.writer = WebPMemoryWrite;
  pic.custom_ptr = &writer;
  const int ok = WebPEncode(&config, &pic);
  WebPPictureFree(&pic);
  if (!ok) {
    WebPMemoryWriterClear(&writer);
    return 0;
  }
  *output = writer.mem;
  return writer.size;
}

SatsumaWebPAnim* SatsumaWebPAnimNew(int width, int height, float quality, int loopCount) {
  WebPAnimEncoderOptions options;
  if (!WebPAnimEncoderOptionsInit(&options)) return NULL;
  options.anim_params.loop_count = loopCount;
  SatsumaWebPAnim* anim = (SatsumaWebPAnim*)calloc(1, sizeof(*anim));
  if (anim == NULL) return NULL;
  anim->width = width;
  anim->height = height;
  if (!Configure(&anim->config, quality, 0)) {
    free(anim);
    return NULL;
  }
  anim->encoder = WebPAnimEncoderNew(width, height, &options);
  if (anim->encoder == NULL) {
    free(anim);
    return NULL;
  }
  return anim;
}

int SatsumaWebPAnimAdd(SatsumaWebPAnim* anim, const uint8_t* rgba, int stride, int timestampMs) {
  WebPPicture pic;
  if (!Import(&pic, rgba, anim->width, anim->height, stride)) return 0;
  const int ok = WebPAnimEncoderAdd(anim->encoder, &pic, timestampMs, &anim->config);
  WebPPictureFree(&pic);
  return ok;
}

size_t SatsumaWebPAnimFinish(SatsumaWebPAnim* anim, int endTimestampMs, uint8_t** output) {
  WebPData data;
  *output = NULL;
  if (!WebPAnimEncoderAdd(anim->encoder, NULL, endTimestampMs, NULL)) return 0;
  WebPDataInit(&data);
  if (!WebPAnimEncoderAssemble(anim->encoder, &data)) {
    WebPDataClear(&data);
    return 0;
  }
  *output = (uint8_t*)data.bytes;
  return data.size;
}

void SatsumaWebPAnimDelete(SatsumaWebPAnim* anim) {
  if (anim == NULL) return;
  WebPAnimEncoderDelete(anim->encoder);
  free(anim);
}

void SatsumaWebPFree(void* ptr) { WebPFree(ptr); }

int SatsumaWebPEncoderVersion(void) { return WebPGetEncoderVersion(); }
