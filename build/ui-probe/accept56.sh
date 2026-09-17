#!/bin/bash
# build/ui-probe/accept56.sh — ⑤ 长标题详情文本比对 + ⑥ 下载提交状态（黑盒，真实 App）
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/资源探测.app"
AX="$ROOT/build/ui-probe/AXProbe"
DRIVE="$ROOT/build/ui-probe/UIDrive"
AUD="python3 $ROOT/build/ui-probe/ui_audit.py"

echo "== 探测 plyr.io（真实网址）=="
"$AX" "$APP" submit "https://plyr.io/" >/dev/null 2>&1
"$AX" "$APP" press "⏎ 重新探测" >/dev/null 2>&1
"$AX" "$APP" watchstatus 50 0.2 | tail -2
echo "== 选中第 1 行 =="
"$DRIVE" "$APP" select-row resource 0
sleep 1.5
echo "== AX 文本快照（列表行 vs 详情标题）=="
$AUD "$APP" texts
echo "== 详情区几何（越界/重叠，只看有尺寸元素）=="
$AUD "$APP" audit 9 | tail -4
echo "== ⑥ 点击「下载」=="
"$AX" "$APP" press "下载" 2>&1 | tail -1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  sleep 0.4
  hit=$("$AX" "$APP" find "已提交下载任务" 2>/dev/null | head -1)
  [ -n "$hit" ] && { echo "命中：$hit"; break; }
done
echo "== 下载列表（只读，不改动用户记录）=="
"$AX" "$APP" press "⌘L 下载列表" >/dev/null 2>&1; sleep 1
"$AX" "$APP" find "个任务" | head -2
"$AX" "$APP" press "← 返回主页" >/dev/null 2>&1
