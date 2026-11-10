#!/bin/bash
# make-fixtures.sh — 预览功能测试夹具生成（第 35 轮）
# 产物：带音轨双档 HLS（明文）+ AES-128 加密单档 + 直链 mp4 + 环回钉选 master
# 用法：bash tests/fixtures/preview/make-fixtures.sh [输出目录]
#
# ⚠ 能力要求（第 46 轮修）：本脚本需要**带编码器**的完整 ffmpeg
#   （libx264 / aac / hls muxer / lavfi 输入）。项目内置的
#   `resources/Resources/MediaTools/ffmpeg` 是**只读裁剪版**——`-demuxers` 有 hls、
#   `-muxers` 只有 adts/mp4/mpegts，`-encoders` 与 `-filters` **全空**、无 lavfi 输入，
#   因此它**永远无法**造夹具。此前脚本只检查 `-muxers | grep " hls "`，报错文案却写
#   「设 MILIU_FFMPEG 指向完整版」——实测把 MILIU_FFMPEG 指向内置版必然失败，属误导。
#   现改为按「编码器 + lavfi + hls muxer」三项实测判定，并把内置版明确排除。
#
# 退出码约定（第 46 轮新增，供套件分支）：
#   0 = 夹具生成成功
#   3 = 环境不具备（找不到带编码器的完整版 ffmpeg）——**降级而非失败**，
#       调用方应跳过依赖真实媒体的端到端段，纯函数段照常运行。
#   1 = 真实失败（找到了合适的 ffmpeg 但产物不合格）
set -euo pipefail

DIR="${1:-$(cd "$(dirname "$0")" && pwd)/build}"
FF="${MILIU_FFMPEG:-}"
BUILTIN="$(cd "$(dirname "$0")/../../.." && pwd)/resources/Resources/MediaTools/ffmpeg"

# 判定某 ffmpeg 是否具备造流能力：编码器（h264/aac）+ lavfi 输入 + hls muxer。
ff_can_encode() {
  local exe="$1"
  [ -n "$exe" ] && [ -x "$exe" ] || return 1
  "$exe" -hide_banner -muxers   2>/dev/null | grep " hls " >/dev/null || return 1
  "$exe" -hide_banner -demuxers 2>/dev/null | grep " lavfi" >/dev/null || return 1
  "$exe" -hide_banner -encoders 2>/dev/null | grep -E " (libx264|h264) " >/dev/null || return 1
  "$exe" -hide_banner -encoders 2>/dev/null | grep -E " aac " >/dev/null || return 1
  return 0
}

find_ff() {
  local cand
  # 1) 显式指定（但必须真能编码，否则给出准确原因而不是让它在后面炸）
  if [ -n "$FF" ]; then
    if ff_can_encode "$FF"; then echo "$FF"; return 0; fi
    echo "WARN: MILIU_FFMPEG=$FF 不具备造流能力（需 hls muxer + lavfi + h264 + aac 四者齐备）" >&2
    case "$FF" in
      "$BUILTIN"|*MediaTools/ffmpeg)
        echo "WARN: 该路径是项目内置只读裁剪版（无编码器、无 lavfi），用它造夹具必然失败——" >&2
        echo "WARN: 内置版只服务生产合流（demux → -c copy → mp4），不是造流工具。" >&2 ;;
    esac
  fi
  # 2) 影像站 runtime（历史完整版）
  cand="/Volumes/SEVEN/资料库/_sys/seven-影像站/runtime/bin/ffmpeg"
  ff_can_encode "$cand" && { echo "$cand"; return 0; }
  # 3) PATH 上的 ffmpeg / ffmpeg-full（Homebrew 常见名）
  for cand in ffmpeg ffmpeg-full; do
    cand="$(command -v "$cand" 2>/dev/null || true)"
    ff_can_encode "$cand" && { echo "$cand"; return 0; }
  done
  # 4) Homebrew 常见安装位置（非交互 shell 的 PATH 可能没有）
  for cand in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
    ff_can_encode "$cand" && { echo "$cand"; return 0; }
  done
  return 1
}

if ! FF="$(find_ff)"; then
  cat >&2 <<'MSG'
SKIP: 找不到带编码器的完整版 ffmpeg，无法生成预览夹具（环境缺失，非产品缺陷）。
      需要：hls muxer + lavfi 输入 + h264 编码器 + aac 编码器。
      安装任一即可：brew install ffmpeg
      或设 MILIU_FFMPEG=/path/to/full-ffmpeg
      注意：项目内置 resources/Resources/MediaTools/ffmpeg 是只读裁剪版，不能用于造流。
MSG
  exit 3
fi

# Caller supplies a fresh isolated directory. Never recursively delete a supplied path.
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
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
