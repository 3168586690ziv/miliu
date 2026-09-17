#!/bin/bash
# build/ui-probe/accept4.sh — 黑盒验收④：输入真实网址，抓取探测状态文案序列
set -u
APP="/build-user/Documents/资源探测-GitHub源码/build/资源探测.app"
AX="/build-user/Documents/资源探测-GitHub源码/build/ui-probe/AXProbe"
TYPE="/build-user/Documents/资源探测-GitHub源码/build/ui-probe/UIType"
URL="${1:-https://plyr.io/}"
WATCH="${2:-70}"

"$AX" "$APP" pressid "RDBackButton" >/dev/null 2>&1
sleep 0.5
"$AX" "$APP" focus-text
"$TYPE" "$APP" "$URL"
sleep 0.8
echo "--- 输入框内容确认 ---"
"$AX" "$APP" find "$URL" | tail -3
echo "--- 回车开始探测，轮询状态行 ${WATCH}s ---"
"$TYPE" "$APP" --key return
"$AX" "$APP" watchstatus "$WATCH" 0.15
