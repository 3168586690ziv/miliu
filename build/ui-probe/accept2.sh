#!/bin/bash
# build/ui-probe/accept2.sh — 黑盒验收②：关闭并重启 App，比例设置保留
set -u
APP="/build-user/Documents/资源探测-GitHub源码/build/资源探测.app"
AX="/build-user/Documents/资源探测-GitHub源码/build/ui-probe/AXProbe"
AUD="python3 /build-user/Documents/资源探测-GitHub源码/build/ui-probe/ui_audit.py"
BID="com.sevenzz.resource-detector"

echo "== 步骤1：改成「左 2.5 : 右 7.5」"
"$AX" "$APP" press "设置" >/dev/null 2>&1; sleep 0.5
"$AX" "$APP" popup-pick "左 2.5 : 右 7.5" >/dev/null 2>&1; sleep 0.4
"$AX" "$APP" press "← 返回探测" >/dev/null 2>&1; sleep 0.7
$AUD "$APP" panes
echo "存储值=$(defaults read "$BID" ZZResourceDetector.MainPaneRatio 2>/dev/null)"

echo "== 步骤2：⌘Q 退出，确认进程消失"
"$AX" "$APP" quit >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; if ! "$AX" "$APP" windows 2>/dev/null | grep -q WINDOW; then echo "已在第 ${i}s 退出"; break; fi; done
"$AX" "$APP" windows 2>&1 | head -2

echo "== 步骤3：重新启动，读回比例"
open -n "$APP"; sleep 5
"$AX" "$APP" info
"$AX" "$APP" press "设置" >/dev/null 2>&1; sleep 0.6
"$AX" "$APP" find "RDPaneRatioPopup" | head -3
"$AX" "$APP" press "← 返回探测" >/dev/null 2>&1; sleep 0.7
$AUD "$APP" panes
echo "存储值=$(defaults read "$BID" ZZResourceDetector.MainPaneRatio 2>/dev/null)"
