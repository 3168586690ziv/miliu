#!/bin/bash
# run-one-site.sh — 单站探测执行器（被 run-corpus.sh 并行调用）
# 用法：bash tools/run-one-site.sh <序号> <URL>
# 环境：REPO / MODE / TIMEOUT / OUT / CORPUS（由 run-corpus.sh 导出）
set -uo pipefail

idx="$1"; url="$2"
log="$OUT/logs/$idx.log"
start=$(python3 -c 'import time;print(time.time())')

# 直接用预编译探针（run-corpus.sh 已确保二进制就绪），跳过每站重复编译。
# 超时控制用 python（macOS 无 GNU timeout）：SIGTERM → 2s → SIGKILL。
RD_LOG_PATH="$OUT/logs/$idx-rdlog.log" python3 - "$TIMEOUT" "$PROBE_BIN" "$MODE" "$url" "$log" <<'PYEOF'
import os, subprocess, sys, signal
timeout = float(sys.argv[1]); script = sys.argv[2]
args = sys.argv[3:5]; logpath = sys.argv[5]
with open(logpath, "wb") as lf:
    p = subprocess.Popen([script] + args, stdout=lf, stderr=subprocess.STDOUT,
                         env=dict(os.environ), start_new_session=True)
    try:
        p.wait(timeout=timeout); rc = p.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGTERM); p.wait(timeout=2)
        except Exception:
            try: os.killpg(p.pid, signal.SIGKILL)
            except Exception: pass
        rc = 124
sys.exit(rc)
PYEOF
rc=$?

end=$(python3 -c 'import time;print(time.time())')
dur=$(python3 -c "print(f'{$end-$start:.1f}')")

# 从探针输出取结构化结论（兼容多种输出形态）
media=$(grep -oE 'RS-MEDIA[^=]*=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$')
video=$(grep -oE 'RS-VIDEO[^=]*=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$')
image=$(grep -oE 'RS-IMAGE[^=]*=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$')
detail=$(grep -oE 'RS-DETAIL[^=]*=[^[:space:]]+' "$log" | tail -1 | cut -d= -f2-)
[ -n "${media:-}" ] || media=$(grep -oE '发现 [0-9]+ 个' "$log" | tail -1 | grep -oE '[0-9]+')
# 再兜底：数 count= 或 media= 形态
[ -n "${media:-}" ] || media=$(grep -oE 'media=[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+')
[ -n "${media:-}" ] || media="-"
[ -n "${video:-}" ] || video="-"
[ -n "${image:-}" ] || image="-"
[ -n "${detail:-}" ] || detail="-"

# 状态以「是否抓到资源」为准（探针的 RS-RESULT 是它自身的验收自检，
# 与抓取能力是两回事——那些结论单独记在 check 列，不污染成败判定）。
verdict=$(grep -oE 'RS-RESULT (PASS|FAIL)' "$log" | tail -1 | awk '{print $2}')
if [ "$rc" -eq 124 ]; then status="TIMEOUT"
elif [ "$media" != "-" ] && [ "$media" -gt 0 ] 2>/dev/null; then
  if [ "$verdict" = "FAIL" ]; then status="OK-CHECK"; else status="OK"; fi
elif [ "$rc" -eq 0 ]; then status="ZERO"
elif [ "$rc" -eq 1 ] && [ "$verdict" = "FAIL" ]; then status="OK-CHECK"
else status="FAIL($rc)"; fi
# 验收自检结论独立列
check="${verdict:-none}"

# 归因升级（2026-10-06 修正）：原版只看探针第一跳状态码，把 301/307
# 重定向站点误报成 404。现在按「确定拒绝 / 可达但无媒体 / 未完成」三层判定，
# 且重定向类单独标注，不再冤枉产品也不再掩盖真实原因。
cause="-"
if grep -qE '降级|downgrade' "$log"; then cause="安全策略拦截"
elif grep -qE 'DRM|Widevine|FairPlay' "$log"; then cause="DRM"
elif grep -qE 'HTTP 40[13]|403 Forbidden|401 Unauthorized' "$log"; then cause="反爬(403/401)"
elif grep -qE 'HTTP 404' "$log"; then cause="404(URL已失效)"
elif grep -qE '页面定稿 media=0' "$log" && grep -qE '\[probe\] WebKit 会话开始' "$log"; then
  # 页面确实加载过、但零媒体：多数是登录墙/JS 壳页/纯导航页，不是被拒绝
  cause="可达但无媒体(登录墙/壳页)"
elif grep -qE '超时|timed out|timedout' "$log"; then cause="超时"
elif [ "$status" = "ZERO" ]; then cause="可达但无媒体(登录墙/壳页)"
fi

cat=$(python3 - "$CORPUS" "$url" <<'PY'
import sys
corpus, url = sys.argv[1], sys.argv[2]
c = "未分类"
for line in open(corpus, encoding='utf-8'):
    if line.startswith('##'):
        name = line.lstrip('#').strip().lstrip('─ ').strip()
        if name: c = name
    elif line.strip() == url:
        break
print(c)
PY
)

printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$status" "$dur" "$media" "$video" "$image" "$detail" "$cause" "$cat" "$check" "$url" >> "$OUT/results.tsv"
