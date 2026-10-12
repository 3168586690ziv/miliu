#!/bin/bash
# extract-media-links.sh — 从站点首页批量提取媒体直链（100 站测速的语料准备步骤）
#
# 用途：download-speed-run.sh 需要的是「可下载的媒体直链」语料，
#       而 prefilter-sites.py 产出的是「有视频内容的站点首页」。
#       本脚本把前者转成后者：对每个站点跑 Miliu 真实探针（hybrid 模式，静态+动态腿），
#       解析出媒体地址，配合 curl 拿时长，按时长档位归档。
#
# 用法：
#   bash tools/extract-media-links.sh <站点列表文件> <输出目录> [--jobs N] [--timeout S]
#
# 输入：每行一个站点首页 URL（井号注释）
# 输出（落在输出目录）：
#   media.tsv        每行：媒体直链 \t referer(站点页) \t 标题 \t 时长秒 \t 档位
#   failed.txt       未提取到媒体的站点
#   logs/<n>.log     每站探针完整输出
#
# 为什么用真实探针而不是自己写正则：探针走的正是生产链路（静态腿 + 动态 WebKit 腿），
# 提取到的直链与用户在 APP 里看到的完全一致，测速结果才代表真实使用。
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_BIN="$REPO/build/real-site-probe/RealSiteProbe"

LIST="$1"
OUTDIR="$2"
JOBS=4
TIMEOUT=90
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -f "$LIST" ] || { echo "FAIL: 站点列表不存在：$LIST" >&2; exit 2; }
[ -x "$PROBE_BIN" ] || { echo "FAIL: 探针未编译：先跑 bash tests/Tests/real-site.sh selfcheck" >&2; exit 1; }
mkdir -p "$OUTDIR/logs"
MEDIA="$OUTDIR/media.tsv"
: > "$MEDIA"
: > "$OUTDIR/failed.txt"

echo "== 媒体直链提取 =="
echo "站点列表：$LIST（$(grep -vcE '^#|^$' "$LIST" || true) 条）"
echo "输出：$OUTDIR"

# 单站处理：探针 hybrid → 解析出媒体 URL → curl 拿时长
extract_one() {
  local idx="$1" site="$2"
  local log="$OUTDIR/logs/$idx.log"
  RD_LOG_PATH="$OUTDIR/logs/$idx-rdlog.log" \
  python3 - "$TIMEOUT" "$PROBE_BIN" "$site" "$log" <<'PYEOF'
import os, subprocess, sys, signal
timeout = float(sys.argv[1]); script = sys.argv[2]; site = sys.argv[3]; logpath = sys.argv[4]
with open(logpath, "wb") as lf:
    p = subprocess.Popen([script, "hybrid", site], stdout=lf, stderr=subprocess.STDOUT,
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
  return $?
}
export -f extract_one
export OUTDIR TIMEOUT PROBE_BIN

# 并发提取
idx=0
while IFS= read -r site; do
  case "$site" in ''|\#*) continue ;; esac
  idx=$((idx + 1))
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || sleep 0.2; done
  extract_one "$(printf '%04d' "$idx")" "$site" &
done < <(grep -vE '^#|^$' "$LIST")
wait

# 解析：从所有站点日志里收媒体 URL（探针输出里 RS-MEDIA / media= 行）
python3 - "$OUTDIR" "$MEDIA" <<'PYEOF'
import os, re, sys, glob, urllib.parse
outdir, media_path = sys.argv[1], sys.argv[2]
MEDIA_RE = re.compile(r'(https?://[^\s"\'<>]+\.(?:mp4|mov|m4v|webm))(?:\?[^\s"\'<>]*)?', re.I)
seen = set()
rows = []
for log in sorted(glob.glob(os.path.join(outdir, "logs", "*.log"))):
    try:
        text = open(log, encoding="utf-8", errors="replace").read()
    except Exception:
        continue
    for m in MEDIA_RE.finditer(text):
        url = m.group(0)
        if url in seen:
            continue
        seen.add(url)
        rows.append(url)
with open(media_path, "w", encoding="utf-8") as f:
    for u in rows:
        f.write(u + "\n")
print(f"提取到媒体直链：{len(rows)} 条")
PYEOF

echo "完成。媒体直链清单：$MEDIA"
echo "下一步：用 curl 拿时长并按时长档位归档，再喂给 download-speed-run.sh"
