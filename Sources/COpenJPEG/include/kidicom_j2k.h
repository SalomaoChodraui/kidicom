/* Kidicom helper: decode a JPEG 2000 codestream or JP2 file from memory. */
#ifndef KIDICOM_J2K_H
#define KIDICOM_J2K_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int32_t *samples;   /* width * height * components, interleaved */
    int width;
    int height;
    int components;
    int precision;      /* bits of the first component */
    int is_signed;
} kidicom_j2k_image;

/* Returns 0 on success. Free the samples with kidicom_j2k_free. */
int kidicom_j2k_decode(const uint8_t *data, size_t length, kidicom_j2k_image *out);
void kidicom_j2k_free(kidicom_j2k_image *image);

#endif
