#!/bin/bash
# build/ui-probe/accept_all.sh — 黑盒验收 ③④⑤⑥⑦ 一体化（用 build.sh 产出的 build/资源探测.app）
# 用法：bash build/ui-probe/accept_all.sh            # 全部
#       bash build/ui-probe/accept_all.sh 4         # 只跑某一项
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/资源探测.app"
AX="$ROOT/build/ui-probe/AXProbe"
TYPE="$ROOT/build/ui-probe/UIType"
DRIVE="$ROOT/build/ui-probe/UIDrive"
AUD="python3 $ROOT/build/ui-probe/ui_audit.py"
ONLY="${1:-all}"

run() { [ "$ONLY" = "all" ] || [ "$ONLY" = "$1" ]; }

if run 4; then
echo "================ ④ 探测阶段文案（真实网址）================"
for u in "https://hlsjs.video-dev.org/demo/" "https://plyr.io/"; do
  echo "--- 网址 $u"
  "$AX" "$APP" pressid "RDBackButton" >/dev/null 2>&1; sleep 0.4
  "$AX" "$APP" submit "$u" >/dev/null 2>&1
  "$AX" "$APP" press "⏎ 重新探测" >/dev/null 2>&1
  "$AX" "$APP" watchstatus 60 0.10
done
fi

if run 5; then
echo "================ ⑤ 长标题：右侧完整显示 + 下方字段/直链/按钮不重叠 ================"
"$AX" "$APP" pressid "RDBackButton" >/dev/null 2>&1; sleep 0.4
"$AX" "$APP" submit "https://plyr.io/" >/dev/null 2>&1
"$AX" "$APP" press "⏎ 重新探测" >/dev/null 2>&1
"$AX" "$APP" watchstatus 45 0.2 | tail -2
"$DRIVE" "$APP" select-row resource 0
sleep 1.5
echo "--- 列表行标题（AX）"
"$AX" "$APP" find "Plyr" | head -4
echo "--- 详情区文本（AX，含坐标）"
$AUD "$APP" texts
fi

if run 6; then
echo "================ ⑥ 点击下载 → 状态「已提交下载任务」================"
"$AX" "$APP" press "下载" >/dev/null 2>&1
rc=$?
echo "press(下载) rc=$rc"
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.4
  line=$("$AX" "$APP" find "已提交" 2>/dev/null | head -1)
  [ -n "$line" ] && { echo "$line"; break; }
done
"$AX" "$APP" find "已提交下载任务" | head -2
echo "--- 下载列表状态（不改动用户记录，仅读取）"
"$AX" "$APP" press "⌘L 下载列表" >/dev/null 2>&1; sleep 0.8
"$AX" "$APP" find "共" | head -2
"$AX" "$APP" press "← 返回主页" >/dev/null 2>&1
fi

if run 3; then
echo "================ ③ 最小窗口（内容区 760×438）：设置页/主界面/详情页逐屏审计 ================"
"$AX" "$APP" resize 760 460
sleep 1
"$AX" "$APP" windows
echo "--- 主界面（含已选中的详情）"
$AUD "$APP" audit 9
echo "--- 设置页"
"$AX" "$APP" press "设置" >/dev/null 2>&1; sleep 0.8
$AUD "$APP" audit 9
for tier in "左 3 : 右 7" "左 2 : 右 8" "左 2.5 : 右 7.5"; do
  "$AX" "$APP" popup-pick "$tier" >/dev/null 2>&1
  sleep 0.5
  echo "--- 设置页（比例 ${tier}）"
  $AUD "$APP" audit 9 | tail -3
done
echo "--- 返回主界面（比例 2.5:7.5 下的左右栏）"
"$AX" "$APP" pressid "RDBackButton" >/dev/null 2>&1; sleep 0.8
$AUD "$APP" panes
$AUD "$APP" audit 9 | tail -3
echo "--- 下载列表页"
"$AX" "$APP" press "⌘L 下载列表" >/dev/null 2>&1; sleep 0.8
$AUD "$APP" audit 9 | tail -3
"$AX" "$APP" press "← 返回主页" >/dev/null 2>&1
fi

if run 7; then
echo "================ ⑦ 连续缩放窗口：文字/分割线/左右栏/详情标题保持稳定 ================"
for wh in "1000 740" "760 460" "900 600" "780 470" "980 700" "760 460"; do
  set -- $wh
  "$AX" "$APP" resize "$1" "$2" >/dev/null 2>&1
  sleep 0.7
  w=$("$AX" "$APP" windows | sed -n 's/.*w=\([0-9]*\) h=\([0-9]*\).*/\1x\2/p' | head -1)
  panes=$($AUD "$APP" panes | tr '\n' ' ')
  title=$($AUD "$APP" element "Plyr" 2>/dev/null | grep "详情标题" | head -1)
  audit=$($AUD "$APP" audit 9 | tail -1)
  echo "窗口=$w | $panes| $audit"
done
echo "--- 最后一次的详情区文本（确认标题/字段仍在）"
$AUD "$APP" texts | grep -E "Plyr|时长|来源|下载直链" | head -6
fi
