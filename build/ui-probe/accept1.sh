#!/bin/bash
# build/ui-probe/accept1.sh — 黑盒验收①：设置页三档比例切换 → 返回主界面，左右宽度即时变化
set -u
APP="/build-user/Documents/资源探测-GitHub源码/build/资源探测.app"
AX="/build-user/Documents/资源探测-GitHub源码/build/ui-probe/AXProbe"
AUD="python3 /build-user/Documents/资源探测-GitHub源码/build/ui-probe/ui_audit.py"
BID="com.sevenzz.resource-detector"

"$AX" "$APP" press "← 返回探测" >/dev/null 2>&1
sleep 0.8
for tier in "左 3 : 右 7" "左 2 : 右 8" "左 2.5 : 右 7.5" "左 2 : 右 8" "左 3 : 右 7"; do
  "$AX" "$APP" press "设置" >/dev/null 2>&1
  sleep 0.5
  "$AX" "$APP" popup-pick "$tier" >/dev/null 2>&1
  rc_pick=$?
  sleep 0.4
  "$AX" "$APP" press "← 返回探测" >/dev/null 2>&1
  sleep 0.7
  echo "### 档位 [$tier] popup_pick_rc=$rc_pick 存储值=$(defaults read "$BID" ZZResourceDetector.MainPaneRatio 2>/dev/null)"
  $AUD "$APP" panes
done
