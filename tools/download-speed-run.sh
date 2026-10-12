#!/bin/bash
# download-speed-run.sh — 100 站下载测速跑器（第 36 轮起）
#
# 目的（主人 2026-10-12 指定）：
#   独立找 100 个站点 → 把资源真实下载到本地 → 按「时长档位」覆盖（0~5 分钟、
#   5~10 分钟、10~20 分钟各若干）→ 逐站测速 → 把「速度异常」归因到两类之一：
#     (a) 网络层：对方服务器限速 / 节点问题 —— 不可改，如实记录
#     (b) 配置层：APP 通病 —— 必须修
#   修复配置层问题后，用**全新一批** 100 站复测（绝不复用上一批）。
#
# 用法：
#   bash tools/download-speed-run.sh [--jobs N] [--timeout S] [--out DIR] [--resume]
#                                    [--referer-mode page|none] <语料文件>
#
# 语料格式（每行一个下载直链）：
#   <media_url>\t<referer_url>\t<标题>[\t<期望高度>]
#   井号开头为注释。前两列为空则跳过。
#
# 输出（全部落在 --out 目录，可断点续跑）：
#   results.tsv   每站一行：序号 状态 耗时秒 字节 平均Bps 分段 段数 回退 首字节 时长秒 档位 referer url
#   summary.txt   汇总：按时长档位 × 速度档位交叉统计 + 归因分流
#   logs/<n>.log  每站完整探针输出
#
# 设计约束（与项目既有跑器一致）：
#   · 不做任何 git / 安装操作，只读下载到独立目录
#   · 每站 RD_LOG_PATH 隔离，不污染用户真实日志
#   · 下载目录落在 --out 下的 media/，不写用户的 ~/Downloads
#   · 每站完成即追加 results.tsv（断点续跑依据），绝不最后统一写
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOBS=4                # 下载会抢占带宽，默认比探测跑器更保守
TIMEOUT=900           # 单站下载上限（含慢站大文件）
OUT=""
RESUME=0
CORPUS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    -*) echo "未知参数：$1" >&2; exit 2 ;;
    *) CORPUS="$1"; shift ;;
  esac
done

[ -n "$CORPUS" ] && [ -f "$CORPUS" ] || { echo "FAIL: 语料文件不存在：$CORPUS" >&2; exit 2; }
if [ -z "$OUT" ]; then
  OUT="$REPO/build/download-speed-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT/logs" "$OUT/media"

PROBE_BIN="$REPO/build/real-site-probe/RealSiteProbe"
MUXER="$REPO/build/Miliu.app/Contents/Resources/MediaTools/ffmpeg"
[ -x "$PROBE_BIN" ] || { echo "FAIL: 探针未编译（先跑 bash tests/Tests/real-site.sh selfcheck）" >&2; exit 1; }
[ -x "$MUXER" ] || MUXER=""

RESULTS="$OUT/results.tsv"
[ -s "$RESULTS" ] || printf 'idx\tstat\telapsed\tbytes\tavg_bps\tsegmented\tsegments\tfallback\tfirst_byte\tduration\ttier\treferer\turl\n' > "$RESULTS"

# 已完成的 URL 集合（断点续跑）
DONE="$OUT/.done-urls"
touch "$DONE"

total=$(grep -vcE '^#|^$' "$CORPUS" || true)
echo "== 下载测速跑器 =="
echo "语料：$CORPUS（$total 条）"
echo "并发：$JOBS  单站超时：${TIMEOUT}s  输出：$OUT"

run_one() {
  local idx="$1" url="$2" referer="$3" title="$4" expect="$5"
  local log="$OUT/logs/$idx.log"
  local dest="$OUT/media"
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')

  # 探针按「下载模式」调用：真实生产 DownloadManager（分段/单连接/校验/落盘）
  RD_LOG_PATH="$OUT/logs/$idx-rdlog.log" \
  RD_PROBE_MUXER_PATH="$MUXER" \
  python3 - "$TIMEOUT" "$PROBE_BIN" "$url" "$referer" "$title" "$expect" "$dest" "$log" <<'PYEOF'
import os, subprocess, sys, signal
timeout = float(sys.argv[1]); script = sys.argv[2]
args = sys.argv[3:8]
logpath = sys.argv[8]
with open(logpath, "wb") as lf:
    p = subprocess.Popen([script, "download"] + args, stdout=lf, stderr=subprocess.STDOUT,
                         env=dict(os.environ), start_new_session=True)
    try:
        p.wait(timeout=timeout); rc = p.returncode
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try: os.killpg(p.pid, sig); p.wait(timeout=3)
            except Exception: pass
        rc = 124
sys.exit(rc)
PYEOF
  local rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  local wall
  wall=$(python3 -c "print(f'{$t1-$t0:.3f}')")

  # 从探针输出解析机器可读行
  local speed_line file_line
  speed_line=$(grep -m1 '^RS-SPEED' "$log" 2>/dev/null || true)
  file_line=$(grep -m1 '^RS-FILE' "$log" 2>/dev/null || true)

  local elapsed bytes avg seg segs fb fb_s duration stat tier
  elapsed=$(printf '%s' "$speed_line" | sed -n 's/.*elapsed=\([0-9.]*\).*/\1/p')
  bytes=$(printf '%s' "$speed_line" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')
  avg=$(printf '%s' "$speed_line" | sed -n 's/.*avg_bps=\([0-9]*\).*/\1/p')
  seg=$(printf '%s' "$speed_line" | sed -n 's/.*segmented=\([0-9]*\).*/\1/p')
  segs=$(printf '%s' "$speed_line" | sed -n 's/.*segments=\([0-9-]*\).*/\1/p')
  fb=$(printf '%s' "$speed_line" | sed -n 's/.*fallback=\([0-9]*\).*/\1/p')
  fb_s=$(printf '%s' "$speed_line" | sed -n 's/.*first_byte_s=\([0-9.]*\).*/\1/p')
  duration=$(printf '%s' "$file_line" | sed -n 's/.*duration=\([0-9.]*\)s.*/\1/p')

  # 时长档位（分钟）：0-5 / 5-10 / 10-20 / 20+
  tier="unknown"
  if [ -n "$duration" ]; then
    tier=$(python3 -c "
d=$duration/60.0
print('0-5min' if d<5 else '5-10min' if d<10 else '10-20min' if d<20 else '20min+')")
  fi

  if [ "$rc" -eq 0 ] && [ -n "$avg" ] && [ "$avg" != "0" ]; then stat="OK"
  elif [ "$rc" -eq 124 ]; then stat="TIMEOUT"
  else stat="FAIL"; fi
  [ -z "$elapsed" ] && elapsed="$wall"
  [ -z "$bytes" ] && bytes="0"
  [ -z "$avg" ] && avg="0"
  [ -z "$seg" ] && seg="0"; [ -z "$segs" ] && segs="0"; [ -z "$fb" ] && fb="0"
  [ -z "$fb_s" ] && fb_s="0"; [ -z "$duration" ] && duration="0"

  # 每站完成即落盘（断点续跑依据；并发下用 flock 串行追加）
  python3 - "$RESULTS" "$idx" "$stat" "$elapsed" "$bytes" "$avg" "$seg" "$segs" "$fb" "$fb_s" "$duration" "$tier" "$referer" "$url" <<'PYEOF'
import sys, fcntl
path = sys.argv[1]
row = "\t".join(sys.argv[2:]) + "\n"
with open(path, "a") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(row)
    f.flush()
    fcntl.flock(f, fcntl.LOCK_UN)
PYEOF

  # 记录已完成 URL（续跑跳过）
  printf '%s\n' "$url" >> "$DONE"
  printf '[%s] %-8s %6.1fs %8s B %10s B/s 分段=%s/%s 回退=%s 时长=%ss %s\n' \
    "$idx" "$stat" "$elapsed" "$bytes" "$avg" "$seg" "$segs" "$fb" "$duration" "$tier"
}
export -f run_one
export OUT PROBE_BIN MUXER TIMEOUT DONE RESULTS

# 并发作业池
idx=0
while IFS=$'\t' read -r url referer title expect; do
  case "$url" in ''|\#*) continue ;; esac
  idx=$((idx + 1))
  if [ "$RESUME" -eq 1 ] && grep -qxF "$url" "$DONE" 2>/dev/null; then
    continue
  fi
  # 控制并发
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.3; done
  printf '%04d' "$idx" > /dev/null
  run_one "$(printf '%04d' "$idx")" "$url" "${referer:-}" "${title:-download}" "${expect:-0}" &
done < <(grep -vE '^#|^$' "$CORPUS")
wait

echo
echo "== 汇总 =="
python3 "$REPO/tools/summarize-download-speed.py" "$RESULTS" "$OUT/summary.txt"
cat "$OUT/summary.txt"
