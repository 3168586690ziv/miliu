#!/bin/bash
# run-corpus.sh — 大规模真实站点并行测试跑器（2026-10-06 建）
#
# 目的：把「抓取能力升级」放到大量真实站点上验证，快速定位真实缺口。
# 用法：
#   bash tools/run-corpus.sh [--jobs N] [--timeout S] [--mode MODE] [--out DIR] <语料文件>
#     --jobs N     并行进程数（默认 6；探测会起 WebKit，别开太大）
#     --timeout S  单站超时秒数（默认 70）
#     --mode M     探测模式：app（默认，生产全链）/ hybrid / static / dynamic
#     --out DIR    结果目录（默认 build/corpus-run-<时间戳>）
#
# 输出：
#   results.tsv   每站一行：状态 耗时秒 资源数 视频数 图片数 详情 分类 URL
#   summary.txt   汇总统计（按分类、失败归因）
#   logs/<n>.log  每站完整探针输出
#
# 设计约束：
#   · 与项目其它测试一致，脚本自身不做任何 git/安装操作，纯只读探测。
#   · 每站的 RD_LOG_PATH 隔离到本结果目录，不污染用户真实日志。
#   · 串行/并行都不改变单站的探测语义（每站独立进程）。
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOBS=6
TIMEOUT=70
MODE="app"
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) JOBS="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -*) echo "未知参数：$1" >&2; exit 2 ;;
    *) CORPUS="$1"; shift ;;
  esac
done

[ -n "${CORPUS:-}" ] || { echo "用法：bash tools/run-corpus.sh [--jobs N] [--timeout S] <语料文件>" >&2; exit 2; }
[ -f "$CORPUS" ] || { echo "语料文件不存在：$CORPUS" >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$REPO/build/corpus-run-$STAMP}"
mkdir -p "$OUT/logs"
RESULTS="$OUT/results.tsv"
: > "$RESULTS"

# 提取有效 URL（去掉注释、空行）
grep -vE '^\s*(#|$)' "$CORPUS" | sed 's/[[:space:]]*$//' > "$OUT/urls.txt"
TOTAL=$(wc -l < "$OUT/urls.txt" | tr -d ' ')
echo "== Miliu 语料跑器 =="
echo "  语料：${CORPUS}（${TOTAL} 站）"
echo "  模式：${MODE} ｜ 并行：${JOBS} ｜ 单站超时：${TIMEOUT}s"
echo "  输出：${OUT}"
echo

# ── 预编译探针（关键：避免每站重复编译，那是并行时最大的时间黑洞）──
PROBE_BIN="$REPO/build/real-site-probe/RealSiteProbe"
if [ ! -x "$PROBE_BIN" ] || [ "${FORCE_REBUILD:-0}" = "1" ]; then
  echo "  预编译探针中（一次即可，之后所有站点复用）..."
  if ! bash "$REPO/tests/Tests/real-site.sh" selfcheck >/dev/null 2>&1; then
    echo "  警告：探针预编译失败，将回退到每站编译（慢）" >&2
  fi
fi
if [ ! -x "$PROBE_BIN" ]; then
  echo "FAIL: 探针二进制不可用：$PROBE_BIN" >&2
  exit 1
fi
echo "  探针就绪：$PROBE_BIN"

# 并行调度：作业池（简单可靠，不用 xargs 的嵌套引号）
export REPO MODE TIMEOUT OUT CORPUS PROBE_BIN

idx=0
while IFS= read -r url; do
  idx=$((idx+1))
  bash "$REPO/tools/run-one-site.sh" "$idx" "$url" &
  # 控制并发
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.3; done
done < "$OUT/urls.txt"
wait

# ── 汇总 ──
SUMMARY="$OUT/summary.txt"
{
  echo "== 汇总（${MODE} 模式，${TOTAL} 站，并行 ${JOBS}）=="
  echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "【总体】"
  awk -F'\t' '{c[$1]++} END {for (k in c) printf "  %-12s %d\n", k, c[k]}' "$RESULTS" | sort
  echo
  echo "【失败/超时归因】"
  awk -F'\t' '$1!="OK" && $1!="OK-CHECK" {c[$7]++} END {for (k in c) printf "  %-16s %d\n", k, c[k]}' "$RESULTS" | sort
  echo
  echo "【按类别】"
  awk -F'\t' '{total[$8]++; if ($1=="OK" || $1=="OK-CHECK") ok[$8]++; if ($1=="ZERO") z[$8]++}
    END {for (k in total) printf "  %-30s 成功 %d / 共 %d（零资源 %d）\n", k, ok[k]+0, total[k], z[k]+0}' "$RESULTS" | sort
  echo
  echo "【成功站点明细】（check=FAIL 表示抓取成功但其自身验收项有未过项）"
  awk -F'\t' '($1=="OK"||$1=="OK-CHECK") {printf "  %-10s %5ss  media=%-4s video=%-3s image=%-3s check=%-5s %s\n", $1, $2, $3, $4, $5, $9, $10}' "$RESULTS"
  echo
  echo "【未成功站点（含原因）】"
  awk -F'\t' '$1!="OK" && $1!="OK-CHECK" {printf "  %-10s %-16s %5ss  %s\n", $1, $7, $2, $10}' "$RESULTS"
} > "$SUMMARY"

cat "$SUMMARY"
echo
echo "完整结果：$RESULTS"
echo "每站日志：$OUT/logs/"
