#!/bin/bash
# 下载列表真实界面回归：在真实构建 App 上验证
#  · 统计文案中的任务数量 == 下载表格可访问行数
#  · “全部 / 下载中 / 已成功 / 已失败”四个筛选各自显示正确行数
#  · 只有筛选结果确实为 0 时才显示空状态
#  · 行内主文本是文件名，不再出现“视频 / 图片”等类型称号
#
# 测试数据通过 NSArgumentDomain 注入（-FinishedDownloadJobs '<plist>'），
# 不写入、不修改用户真实的 UserDefaults 记录。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$REPO/build/觅流.app"
BIN="$APP/Contents/MacOS/SevenZZResourceDetector"
PROCESS_NAME="觅流"

if [ "${RD_SKIP_AX:-0}" = "1" ]; then
  echo "SKIP: RD_SKIP_AX=1，跳过辅助功能自动化检查"
  exit 0
fi

if [ ! -x "$BIN" ]; then
  bash "$REPO/scripts/build.sh" >/tmp/rd-download-list-ui-build.log
fi

pkill -f SevenZZResourceDetector 2>/dev/null || true
sleep 1

# 16 条种子记录：12 已完成 + 3 失败 + 1 已取消
SEED="( "
for i in $(seq 1 12); do
  SEED="$SEED { identifier = \"ui-done-$i\"; state = 6; fileName = \"ui-done-$i.mp4\"; sourceURL = \"https://cdn.example.com/ui-done-$i.mp4\"; destinationURL = \"file:///tmp/ui-done-$i.mp4\"; expectedLength = 1048576; }, "
done
for i in $(seq 1 3); do
  SEED="$SEED { identifier = \"ui-fail-$i\"; state = 5; fileName = \"ui-fail-$i.mp4\"; sourceURL = \"https://cdn.example.com/ui-fail-$i.mp4\"; destinationURL = \"file:///tmp/ui-fail-$i.mp4\"; errorText = \"服务器返回 403，下载中止\"; }, "
done
SEED="$SEED { identifier = \"ui-cancel-1\"; state = 4; fileName = \"ui-cancel-1.mp4\"; sourceURL = \"https://cdn.example.com/ui-cancel-1.mp4\"; destinationURL = \"file:///tmp/ui-cancel-1.mp4\"; }, )"

"$BIN" -FinishedDownloadJobs "$SEED" >/tmp/rd-download-list-ui-app.log 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 40); do
  if osascript -e "tell application \"System Events\" to tell process \"$PROCESS_NAME\" to count of windows" >/dev/null 2>&1; then
    if [ "$(osascript -e "tell application \"System Events\" to tell process \"$PROCESS_NAME\" to count of windows" 2>/dev/null)" -gt 0 ]; then break; fi
  fi
  sleep 0.5
done

RESULT="$(osascript <<'APPLESCRIPT' 2>&1
tell application "System Events" to tell process "觅流"
  tell window 1
    click (first button whose name contains "下载列表")
    delay 1.2
    set statuses to (value of every static text) as string
    set totalRows to count of rows of table 1 of scroll area 1
    set out to "STATUS=" & statuses & linefeed
    set out to out & "TOTALROWS=" & totalRows & linefeed
    -- 行内主文本（文件名）：cell 把文件名标签暴露为嵌套的可访问元素
    click (first button whose name is "全部")
    delay 0.5
    repeat with i from 1 to (count of rows of table 1 of scroll area 1)
      set r to row i of table 1 of scroll area 1
      set v to ""
      try
        set v to value of (UI element 1 of UI element 1 of r) as string
      end try
      set out to out & "ROWNAME=" & v & linefeed
    end repeat
    repeat with labelName in {"全部", "下载中", "已成功", "已失败"}
      click (first button whose name is labelName)
      delay 0.4
      set rowCount to count of rows of table 1 of scroll area 1
      set out to out & labelName & "=" & rowCount & linefeed
    end repeat
    click (first button whose name is "下载中")
    delay 0.4
    set emptyWhenZero to (count of (static texts whose value is "暂无下载任务")) > 0
    click (first button whose name is "全部")
    delay 0.4
    set emptyWhenFull to (count of (static texts whose value is "暂无下载任务")) > 0
    set out to out & "EMPTY_WHEN_ZERO=" & emptyWhenZero & linefeed
    set out to out & "EMPTY_WHEN_FULL=" & emptyWhenFull & linefeed
    return out
  end tell
end tell
APPLESCRIPT
)"

kill "$APP_PID" 2>/dev/null || true

echo "$RESULT"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 本次注入的是 16 条历史记录（12 完成 + 3 失败 + 1 取消）。App 还会按用户真实
# 中断记录补出额外行——那是用户自己的数据，测试不得依赖"用户没有记录"，也绝不
# 能通过清空用户记录来凑数。因此把期望值按真实中断记录数做增量。
REAL_INTERRUPTED=$(defaults read com.sevenzz.resource-detector InterruptedDownloadJobs 2>/dev/null | grep -c 'sourceURL' || true)
case "$REAL_INTERRUPTED" in ''|*[!0-9]*) REAL_INTERRUPTED=0 ;; esac
EXPECT_ALL=$((16 + REAL_INTERRUPTED))
EXPECT_FAILED=$((4 + REAL_INTERRUPTED))
echo "INFO: 注入 16 条；用户真实中断记录 $REAL_INTERRUPTED 条 → 期望总行数 $EXPECT_ALL"

echo "$RESULT" | grep -q "TOTALROWS=$EXPECT_ALL" || fail "全部筛选的表格行数应为 $EXPECT_ALL（16 注入 + $REAL_INTERRUPTED 真实）"
echo "$RESULT" | grep -q "全部=$EXPECT_ALL"      || fail "“全部”筛选应显示 $EXPECT_ALL 行"
echo "$RESULT" | grep -q '下载中=0'              || fail "“下载中”筛选应显示 0 行"
echo "$RESULT" | grep -q '已成功=12'             || fail "“已成功”筛选应显示 12 行"
echo "$RESULT" | grep -q "已失败=$EXPECT_FAILED" || fail "“已失败”筛选应显示 $EXPECT_FAILED 行（失败 3 + 取消 1 + $REAL_INTERRUPTED 真实）"
echo "$RESULT" | grep -q "共 $EXPECT_ALL 个任务"  || fail "统计文案应显示共 $EXPECT_ALL 个任务"
echo "$RESULT" | grep -q 'EMPTY_WHEN_ZERO=true'  || fail "筛选结果为 0 时应显示空状态"
echo "$RESULT" | grep -q 'EMPTY_WHEN_FULL=false' || fail "筛选结果非 0 时不得显示空状态"

# 行内可访问文本：每一行都要读得到文件名，且注入的 16 行必须齐全
ROWNAME_COUNT=$(echo "$RESULT" | grep -c '^ROWNAME=' || true)
NONEMPTY_COUNT=$(echo "$RESULT" | grep '^ROWNAME=' | grep -c 'ROWNAME=ui-' || true)
[ "$ROWNAME_COUNT" = "$EXPECT_ALL" ] || fail "应读取 $EXPECT_ALL 行的可访问文本（实际 $ROWNAME_COUNT）"
[ "$NONEMPTY_COUNT" = "16" ] || fail "注入的 16 行都应读到文件名（实际 $NONEMPTY_COUNT）"
if echo "$RESULT" | grep -q '^ROWNAME=视频\|^ROWNAME=图片'; then
  fail "行内主文本仍以类型称号开头"
fi

echo "PASS: 下载列表真实界面回归通过（行数=$EXPECT_ALL=16 注入 + $REAL_INTERRUPTED 用户中断、四个筛选正确、空状态条件正确、行内为文件名且无类型称号）"
