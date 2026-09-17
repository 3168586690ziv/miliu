#!/bin/bash
# build/ui-probe/accept5.sh — 黑盒验收⑤：选长标题视频，右侧标题完整显示、无尾部省略号、下方字段/按钮/直链不被顶出或重叠
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$REPO/build/资源探测.app"
AX="$REPO/build/ui-probe/AXProbe"
DRIVE="$REPO/build/ui-probe/UIDrive"
AUD="python3 $REPO/build/ui-probe/ui_audit.py"
URL="${1:-https://plyr.io/}"

"$AX" "$APP" submit "$URL" >/dev/null 2>&1
"$AX" "$APP" press "⏎ 重新探测" >/dev/null 2>&1
"$AX" "$APP" watchstatus 45 0.2
echo "== 结果列表中的行标题（AX 读回）=="
"$AX" "$APP" tree 9 2>&1 | grep -A 12 "AXTable" | head -20
echo "== 选中第 1 行 =="
"$DRIVE" "$APP" select-row resource 0
sleep 1.2
echo "== 详情区文本（AX 读回，含坐标）=="
$AUD "$APP" texts
echo "== 详情区几何审计（越界/重叠）=="
$AUD "$APP" audit 9
