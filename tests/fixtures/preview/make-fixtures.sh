#!/bin/bash
# make-fixtures.sh — 预览功能测试夹具生成（第 35 轮）
# 产物：带音轨双档 HLS（明文）+ AES-128 加密单档 + 直链 mp4 + 环回钉选 master
# 用法：bash tests/fixtures/preview/make-fixtures.sh [输出目录]
# ffmpeg 探测顺序：MILIU_FFMPEG → 影像站 runtime（完整版）→ PATH → 项目内置（裁剪版不支持 HLS muxer，仅报错兜底）
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")" && pwd)/build}"
FF="${MILIU_FFMPEG:-}"

find_ff() {
  if [ -n "$FF" ] && [ -x "$FF" ]; then echo "$FF"; return 0; fi
  local cand="/Volumes/SEVEN/资料库/_sys/seven-影像站/runtime/bin/ffmpeg"
  [ -x "$cand" ] && { echo "$cand"; return 0; }
  if command -v ffmpeg >/dev/null 2>&1 && ffmpeg -hide_banner -muxers 2>/dev/null | grep -q " hls "; then
    command -v ffmpeg; return 0
  fi
  return 1
}

FF="$(find_ff)" || { echo "FAIL: 找不到带 hls muxer 的完整版 ffmpeg（设 MILIU_FFMPEG 指向完整版）"; exit 1; }

rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"

# 双档带音轨 HLS（6 秒 testsrc + 440Hz 正弦音，2 秒一片）
"$FF" -y -loglevel error \
  -f lavfi -i testsrc=size=1280x720:rate=25 -t 6 \
  -f lavfi -i "sine=frequency=440:duration=6" \
  -c:v libx264 -b:v 1500k -g 25 -sc_threshold 0 -c:a aac -shortest \
  -hls_time 2 -hls_playlist_type vod \
  -hls_segment_filename "$DIR/avseg720_%03d.ts" "$DIR/av720.m3u8"

"$FF" -y -loglevel error \
  -f lavfi -i testsrc=size=854x480:rate=25 -t 6 \
  -f lavfi -i "sine=frequency=440:duration=6" \
  -c:v libx264 -b:v 800k -g 25 -sc_threshold 0 -c:a aac -shortest \
  -hls_time 2 -hls_playlist_type vod \
  -hls_segment_filename "$DIR/avseg480_%03d.ts" "$DIR/av480.m3u8"

# master（相对路径引用，供钉选改写测试用）
cat > "$DIR/av-master.m3u8" <<'EOF'
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
av720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480
av480.m3u8
EOF

# AES-128 加密单档（keyinfo 第三行 IV 不能带 0x 前缀）
openssl rand -out "$DIR/enc.key" 16
printf '%s\n%s\n%s\n' "enc.key" "$DIR/enc.key" "0123456789ABCDEF0123456789ABCDEF" > "$DIR/enc.keyinfo"
"$FF" -y -loglevel error \
  -f lavfi -i testsrc=size=1280x720:rate=25 -t 6 \
  -f lavfi -i "sine=frequency=440:duration=6" \
  -c:v libx264 -b:v 1500k -g 25 -sc_threshold 0 -c:a aac -shortest \
  -hls_key_info_file "$DIR/enc.keyinfo" \
  -hls_time 2 -hls_playlist_type vod \
  -hls_segment_filename "$DIR/avencseg_%03d.ts" "$DIR/av-enc.m3u8"

# 直链 mp4（带音轨，供 AVPlayer 直连播放验证）
"$FF" -y -loglevel error \
  -f lavfi -i testsrc=size=1280x720:rate=25 -t 6 \
  -f lavfi -i "sine=frequency=440:duration=6" \
  -c:v libx264 -b:v 1500k -g 25 -sc_threshold 0 -c:a aac -shortest \
  "$DIR/direct.mp4"

# 环回钉选 master（绝对 URL 分片，PORT 由 PREVIEW_PORT 决定）
PORT="${PREVIEW_PORT:-8901}"
cat > "$DIR/pinned-http.m3u8" <<EOF
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
http://127.0.0.1:$PORT/av720.m3u8
EOF

# 自检
fail=0
for f in av720.m3u8 av480.m3u8 av-master.m3u8 av-enc.m3u8 direct.mp4 pinned-http.m3u8; do
  [ -s "$DIR/$f" ] || { echo "FAIL: $f 缺失或为空"; fail=1; }
done
for t in "$DIR"/avseg720_*.ts "$DIR"/avseg480_*.ts "$DIR"/avencseg_*.ts; do
  size=$(stat -f %z "$t" 2>/dev/null || echo 0)
  [ "$size" -ge 50000 ] || { echo "FAIL: $t 只有 $size 字节（<50KB）"; fail=1; }
done
[ "$(wc -c < "$DIR/enc.key" | tr -d ' ')" = "16" ] || { echo "FAIL: enc.key 不是 16 字节"; fail=1; }
[ "$fail" = "0" ] || exit 1
echo "OK: 夹具生成于 ${DIR}（ffmpeg: ${FF}）"
