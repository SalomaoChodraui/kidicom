/* Kidicom helper: decode a JPEG 2000 codestream or JP2 file from memory. */
#include "kidicom_j2k.h"
#include "openjpeg.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *data;
    size_t length;
    size_t offset;
} memory_stream;

static OPJ_SIZE_T read_fn(void *buffer, OPJ_SIZE_T count, void *user) {
    memory_stream *s = (memory_stream *)user;
    if (s->offset >= s->length) return (OPJ_SIZE_T)-1;
    size_t n = s->length - s->offset;
    if (n > count) n = count;
    memcpy(buffer, s->data + s->offset, n);
    s->offset += n;
    return n;
}

static OPJ_OFF_T skip_fn(OPJ_OFF_T count, void *user) {
    memory_stream *s = (memory_stream *)user;
    if (count < 0) return -1;
    size_t n = s->length - s->offset;
    if ((size_t)count < n) n = (size_t)count;
    s->offset += n;
    return (OPJ_OFF_T)n;
}

static OPJ_BOOL seek_fn(OPJ_OFF_T position, void *user) {
    memory_stream *s = (memory_stream *)user;
    if (position < 0 || (size_t)position > s->length) return OPJ_FALSE;
    s->offset = (size_t)position;
    return OPJ_TRUE;
}

int kidicom_j2k_decode(const uint8_t *data, size_t length, kidicom_j2k_image *out) {
    memset(out, 0, sizeof(*out));
    if (length < 12) return 1;
    /* JP2 files start with a signature box; raw codestreams with FF4F. */
    OPJ_CODEC_FORMAT format = (data[0] == 0xFF && data[1] == 0x4F) ? OPJ_CODEC_J2K : OPJ_CODEC_JP2;

    memory_stream source = { data, length, 0 };
    opj_stream_t *stream = opj_stream_create(OPJ_J2K_STREAM_CHUNK_SIZE, OPJ_TRUE);
    if (!stream) return 2;
    opj_stream_set_user_data(stream, &source, NULL);
    opj_stream_set_user_data_length(stream, length);
    opj_stream_set_read_function(stream, read_fn);
    opj_stream_set_skip_function(stream, skip_fn);
    opj_stream_set_seek_function(stream, seek_fn);

    opj_codec_t *codec = opj_create_decompress(format);
    opj_dparameters_t parameters;
    opj_set_default_decoder_parameters(&parameters);
    opj_image_t *image = NULL;
    int result = 3;
    if (codec && opj_setup_decoder(codec, &parameters)
        && opj_read_header(stream, codec, &image)
        && opj_decode(codec, stream, image)
        && opj_end_decompress(codec, stream)) {
        int width = (int)image->comps[0].w;
        int height = (int)image->comps[0].h;
        int n = (int)image->numcomps;
        int same = 1;
        for (int c = 1; c < n; c++) {
            if ((int)image->comps[c].w != width || (int)image->comps[c].h != height) same = 0;
        }
        if (same && width > 0 && height > 0) {
            size_t pixels = (size_t)width * (size_t)height;
            out->samples = (int32_t *)malloc(pixels * (size_t)n * sizeof(int32_t));
            if (out->samples) {
                for (int c = 0; c < n; c++) {
                    const OPJ_INT32 *plane = image->comps[c].data;
                    for (size_t i = 0; i < pixels; i++) out->samples[i * n + c] = plane[i];
                }
                out->width = width;
                out->height = height;
                out->components = n;
                out->precision = (int)image->comps[0].prec;
                out->is_signed = (int)image->comps[0].sgnd;
                result = 0;
            }
        } else {
            result = 4;
        }
    }
    if (image) opj_image_destroy(image);
    if (codec) opj_destroy_codec(codec);
    opj_stream_destroy(stream);
    return result;
}

void kidicom_j2k_free(kidicom_j2k_image *image) {
    free(image->samples);
    image->samples = NULL;
}
