# libwebp

A copy of [libwebp](https://chromium.googlesource.com/webm/libwebp) 1.6.0 (tag `v1.6.0`, commit
`4fa21912338357f89e4fd51cf2368325b59e9bd9`), used for WebP output on macOS. ImageIO reads WebP but can't
write it.

Only the library sources are here: `src/dec`, `src/dsp`, `src/enc`, `src/mux`, `src/utils`, the public
headers in `src/webp`, and `sharpyuv`. The files are unchanged from the release, and so are `COPYING`,
`PATENTS` and `AUTHORS`. The app bundle carries `COPYING` and `PATENTS` in `Contents/Resources/Licenses`.

`include/CWebP.h` and `shim/webp_shim.c` are Satsuma's own code: a few functions for still and animated
encoding, so the Swift side never touches libwebp's structs.

To update, replace those folders with the same ones from a newer release tag, and check that the tag's
commit matches upstream:

    git ls-remote https://chromium.googlesource.com/webm/libwebp "refs/tags/v1.6.0^{}"
