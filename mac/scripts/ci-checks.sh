#!/bin/bash
# Runs the command line checks against real sample files and renders the test PNGs.
# Used by .github/workflows/mac.yml; also works locally after `swift build`.
set -u
cd "$(dirname "$0")/.."
BIN="${BIN:-.build/debug/Satsuma}"
OUT="${OUT:-ci-out}"
rm -rf "$OUT"
mkdir -p "$OUT/results"
export SATSUMA_LOG_STDERR=1
fails=0

run() {
    local name="$1"; shift
    if "$BIN" "$@" --result "$OUT/results/$name.json" > "$OUT/results/$name.log" 2>&1; then
        echo "ok    $name"
    else
        echo "FAIL  $name"
        fails=$((fails + 1))
        tail -n 4 "$OUT/results/$name.log" | sed 's/^/        /'
    fi
}

# Checks that must fail with a known message (features that need FFmpeg, inputs a tool can't use).
expect() {
    local name="$1" message="$2"; shift 2
    "$BIN" "$@" --result "$OUT/results/$name.json" > "$OUT/results/$name.log" 2>&1
    if grep -q "$message" "$OUT/results/$name.json" 2>/dev/null; then
        echo "ok    $name (expected: $message)"
    else
        echo "FAIL  $name (expected \"$message\")"
        fails=$((fails + 1))
        tail -n 4 "$OUT/results/$name.log" | sed 's/^/        /'
    fi
}

run samples --make-samples "$OUT/samples"
S="$OUT/samples"
run selftest --selftest "$S/photo.jpg" "$S/doc.pdf"
run list-photo --list "$S/photo.jpg"

# Images
for t in png heic tiff bmp ico pdf; do run "photo-$t" --convert "$t" "$S/photo.jpg"; done
if [ -z "$(command -v ffmpeg)" ]; then
    expect photo-webp "needs FFmpeg" --convert webp "$S/photo.jpg"
    expect photo-avif "needs FFmpeg" --convert avif "$S/photo.jpg"
    expect gif-webm "needs FFmpeg" --convert webm "$S/anim.gif"
    expect mov-mkv "FFmpeg isn't installed" --convert mkv "$S/clip.mov"
    expect wav-mp3 "FFmpeg isn't installed" --convert mp3 "$S/tone.wav"
    expect loudness "Loudness needs FFmpeg" --tool normalize "$S/tone.wav"
fi
for t in jpg pdf; do run "logo-$t" --convert "$t" "$S/logo.png"; done
for t in png jpg; do run "svg-$t" --convert "$t" "$S/badge.svg"; done
for t in mp4 png pdf; do run "gif-$t" --convert "$t" "$S/anim.gif"; done
for t in rotate metadata ocr compress resize background; do run "tool-$t" --tool "$t" "$S/photo.jpg"; done
expect tool-redact "No faces found" --tool redact "$S/photo.jpg"
run tool-makepdf --tool makepdf "$S/photo.jpg" "$S/logo.png"
run tool-collage --tool collage "$S/photo.jpg" "$S/logo.png" "$S/photo.jpg"

# PDF
for t in png jpg txt md html epub docx; do run "pdf-$t" --convert "$t" "$S/doc.pdf"; done
for t in split extract images copytext count; do run "pdftool-$t" --tool "$t" "$S/doc.pdf"; done
expect pdftool-compress "already compact" --tool compress "$S/doc.pdf"

# Documents, sheets, subtitles
for t in html docx pdf txt epub rtf; do run "md-$t" --convert "$t" "$S/notes.md"; done
for t in pdf txt md html rtf odt epub; do run "docx-$t" --convert "$t" "$S/report.docx"; done
for t in pdf docx txt; do run "rtf-$t" --convert "$t" "$S/report.rtf"; done
for t in docx txt; do run "odt-$t" --convert "$t" "$S/report.odt"; done
for t in pdf docx md; do run "html-$t" --convert "$t" "$S/page.html"; done
for t in docx pdf md; do run "txt-$t" --convert "$t" "$S/notes.txt"; done
for t in xlsx json ods html pdf tsv; do run "csv-$t" --convert "$t" "$S/table.csv"; done
for t in csv json ods; do run "xlsx-$t" --convert "$t" "$S/table.xlsx"; done
run ods-xlsx --convert xlsx "$S/table.ods"
for t in vtt txt; do run "srt-$t" --convert "$t" "$S/subs.srt"; done

# Audio and video (native paths; FFmpeg ones report that FFmpeg is missing)
for t in mp4 gif; do run "mov-$t" --convert "$t" "$S/clip.mov"; done
for t in m4a aiff flac; do run "wav-$t" --convert "$t" "$S/tone.wav"; done
run m4a-wav --convert wav "$S/tone.m4a"
run flac-wav --convert wav "$S/tone.flac"
for t in mute 720p rotate snapshot compress; do run "videotool-$t" --tool "$t" "$S/clip.mov"; done
for t in mono fade compress; do run "audiotool-$t" --tool "$t" "$S/tone.wav"; done
run video-merge --tool merge "$S/clip.mov" "$S/clip.mov"

# Archives
for t in zip tar tgz 7z; do run "folder-$t" --convert "$t" "$S/Project"; done
run zip-extract --convert extract "$S/Project.zip"
run zip-to-7z --convert 7z "$S/Project.zip"
run folder-size --tool info "$S/Project"

run render --render-test "$OUT/render"
run render-ui --render-ui "$OUT/ui" "$S/photo.jpg" "$S/clip.mov" "$S/tone.wav" "$S/doc.pdf"

echo
echo "$fails check(s) failed"
ls -la "$S" > "$OUT/samples-listing.txt"
exit $(( fails > 0 ? 1 : 0 ))
