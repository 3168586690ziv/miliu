#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$ROOT/ffmpeg-8.0" ]; then tar -xJf "$ROOT/ffmpeg-8.0.tar.xz" -C "$ROOT"; fi
SOURCE="$ROOT/ffmpeg-8.0"
SDK="$(xcrun --show-sdk-path)"
for ARCH in arm64 x86_64; do
  mkdir -p "$ROOT/$ARCH"
  cd "$ROOT/$ARCH"
  "$SOURCE/configure" --cc=clang --arch="$ARCH" --target-os=darwin --enable-cross-compile \
    --extra-cflags="-arch $ARCH -mmacosx-version-min=13.0 -isysroot $SDK" \
    --extra-ldflags="-arch $ARCH -mmacosx-version-min=13.0 -isysroot $SDK" \
    --disable-autodetect --disable-everything --disable-doc --disable-debug --disable-shared --enable-static \
    --disable-network --disable-x86asm --disable-audiotoolbox --disable-videotoolbox --disable-securetransport \
    --enable-ffmpeg --enable-protocol=file,crypto --enable-demuxer=mov,mpegts,hls,aac,matroska,webvtt \
    --enable-muxer=mp4,mpegts,matroska --enable-parser=h264,hevc,aac --enable-decoder=h264,hevc,aac \
    --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb > configure.log 2>&1
  make -j4 ffmpeg > make.log 2>&1
  cp ffmpeg "$ROOT/ffmpeg-$ARCH"
done
lipo -create "$ROOT/ffmpeg-arm64" "$ROOT/ffmpeg-x86_64" -output "$ROOT/ffmpeg"
codesign --force --sign - "$ROOT/ffmpeg"
"$ROOT/ffmpeg" -hide_banner -protocols > "$ROOT/protocols.txt"
otool -L "$ROOT/ffmpeg" > "$ROOT/libraries.txt"

cp "$ROOT/ffmpeg" "$ROOT/../../Resources/MediaTools/ffmpeg"
