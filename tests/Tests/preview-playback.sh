#!/bin/bash
# preview-playback.sh — 预览播放专项（第 35 轮）
# 结构：判定纯函数测试（子智能体 A）+ 钉选改写纯函数测试（子智能体 C）
#       + 夹具生成与服务器自检 + 端到端段（TODO：主智能体波次 2 填充）
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; ROOT="$REPO/src"
OUT="$REPO/build/preview-tests"
FIX="$REPO/tests/fixtures/preview"
RD="${RD_LOG_PATH:-$OUT/test.log}"

export RD_LOG_PATH="$OUT/test.log"
mkdir -p "$OUT"
exec > >(tee "$OUT/test.log") 2>&1
PORT="${PREVIEW_PORT:-8911}"

compile_component() { # $1=测试名 $2=Tests.m $3=其余 .m 文件列表…
  local name="$1" test_m="$2"; shift 2
  local bin="$OUT/$name"
  xcrun clang -fobjc-arc -g -O1 -mmacosx-version-min=13.0 \
    -framework Foundation -framework AVFoundation -framework CoreMedia -framework Security \
    -I"$ROOT/Features/ResourceDetector" -I"$ROOT" \
    "$REPO/$test_m" "$@" \
    -o "$bin" > "$OUT/$name.compile.log" 2>&1 || return 1
  if grep -E "error:|warning:" "$OUT/$name.compile.log" >/dev/null; then
    cat "$OUT/$name.compile.log"; return 1
  fi
  return 0
}

echo "== 预览套件（第 35 轮）=="

# ── 段 1：判定纯函数（RDPreviewEligibility，子智能体 A 产出）──
if [ -f "$REPO/tests/Tests/PreviewEligibilityTests.m" ] && [ -f "$ROOT/Features/ResourceDetector/RDPreviewEligibility.m" ]; then
  if compile_component PreviewEligibilityTests tests/Tests/PreviewEligibilityTests.m \
       "$ROOT/Features/ResourceDetector/RDPreviewEligibility.m" \
       "$ROOT/Features/ResourceDetector/DetectedMedia.m"; then
    "$OUT/PreviewEligibilityTests"
  else
    echo "FAIL: PreviewEligibilityTests 编译失败（不改对方文件，主智能体协调）"; exit 1
  fi
else
  echo "SKIP: PreviewEligibilityTests 未就绪（并行施工中）"
fi

# ── 段 2：钉选改写纯函数（RDPreviewPlaylistRewrite，子智能体 C 产出）──
if [ -f "$REPO/tests/Tests/PreviewRewriteTests.m" ] && [ -f "$ROOT/Features/ResourceDetector/RDPreviewPlaylistRewrite.m" ]; then
  if compile_component PreviewRewriteTests tests/Tests/PreviewRewriteTests.m \
       "$ROOT/Features/ResourceDetector/RDPreviewPlaylistRewrite.m"; then
    "$OUT/PreviewRewriteTests"
  else
    echo "FAIL: PreviewRewriteTests 编译失败（不改对方文件，主智能体协调）"; exit 1
  fi
else
  echo "SKIP: PreviewRewriteTests 未就绪（并行施工中）"
fi

# ── 段 3：夹具生成 + 服务器自检 ──
export PREVIEW_PORT="$PORT"   # pinned-http.m3u8 里的绝对 URL 必须指向本次服务器端口
bash "$FIX/make-fixtures.sh" "$FIX/build"
python3 "$FIX/server.py" --port "$PORT" --root "$FIX/build" --log "$OUT/server.log" > "$OUT/server.stdout" 2>&1 &
SRV_PID=$!
cleanup() { kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; }
trap cleanup EXIT

for i in $(seq 1 50); do
  grep -q "LISTEN $PORT" "$OUT/server.stdout" 2>/dev/null && break
  [ "$i" = "50" ] && { echo "FAIL: 服务器未就绪"; exit 1; }
  sleep 0.1
done

c1=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/av-master.m3u8")
[ "$c1" = "200" ] || { echo "FAIL: av-master.m3u8 期望 200 实际 $c1"; exit 1; }

curl -s -o /tmp/miliu-preview-range.bin -D "$OUT/range.headers" -r 0-99 "http://127.0.0.1:$PORT/direct.mp4"
c2=$(head -1 "$OUT/range.headers" | awk '{print $2}')
cr=$(grep -i "^Content-Range" "$OUT/range.headers" | tr -d '\r')
[ "$c2" = "206" ] || { echo "FAIL: Range 请求期望 206 实际 $c2"; exit 1; }
[ "$cr" = "Content-Range: bytes 0-99/$(stat -f %z "$FIX/build/direct.mp4")" ] || { echo "FAIL: Content-Range 不符：$cr"; exit 1; }

c3=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/av-enc.m3u8")
[ "$c3" = "200" ] || { echo "FAIL: av-enc.m3u8 期望 200 实际 $c3"; exit 1; }
echo "OK: 服务器自检 3/3（200 / 206+Content-Range / 200）"

# ── 段 4：端到端（与 RDPreviewController 播放管线等价：真 AVPlayer + 同款 Referer options）──
if compile_component PreviewE2E tests/Tests/PreviewE2E.m; then
  # 服务器沿用段 3 的实例（日志含 Referer 全量记录）
  "$OUT/PreviewE2E" "$PORT" "$OUT/server.log"
else
  echo "FAIL: PreviewE2E 编译失败"; exit 1
fi

echo "PASS: 预览套件通过"
