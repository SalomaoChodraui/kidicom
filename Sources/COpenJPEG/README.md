# COpenJPEG

The JPEG 2000 decoder from [OpenJPEG](https://github.com/uclouvain/openjpeg) 2.5.3
(BSD 2-clause, see `LICENSE`), vendored unchanged except for:

- `include/opj_config.h` and `opj_config_private.h`, written by hand in place of the CMake output.
- Left out: benchmark and table generator programs, and the JPIP index managers.

Kidicom uses it only for JPEG 2000 frames, because ImageIO reduces 12- and
16-bit grayscale JPEG 2000 to 8 bits.
