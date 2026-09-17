#!/bin/bash
# 下载列表页面回归测试：验证不再使用独立 NSPanel/NSTextView/NSPopUpButton，
# 主窗口内页面存在返回按钮、四个筛选态、真实列表行、RDThinProgressView 与指标。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$REPO/src"
APP="$ROOT/App/ResourceDetectorApp.m"

# rg 在某些环境中不在默认 PATH，优先使用 WorkBuddy 自带版本
if ! command -v rg >/dev/null 2>&1 && [ -x "/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/ripgrep/arm64-darwin/rg" ]; then
  export PATH="/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/ripgrep/arm64-darwin:$PATH"
fi

cd "$REPO"

# 旧实现必须移除
if rg -q 'downloadsWindow\s*=[[:space:]]*\[\[NSPanel' "$APP"; then
  echo "FAIL: 仍在创建独立 NSPanel 下载窗口" >&2
  exit 1
fi
if rg -q 'NSTextView\s+\*\s*downloadsTextView' "$APP" || rg -q 'downloadsTextView' "$APP"; then
  echo "FAIL: 仍在使用 NSTextView 拼接下载列表文本" >&2
  exit 1
fi
if rg -q 'NSPopUpButton\s+\*\s*downloadJobPicker' "$APP" || rg -q 'downloadJobPicker' "$APP"; then
  echo "FAIL: 仍在使用 NSPopUpButton 作为任务筛选" >&2
  exit 1
fi

# 新页面容器与导航
rg -q 'NSView\s+\*\s*downloadsPage' "$APP" || { echo "FAIL: 缺少 downloadsPage 容器"; exit 1; }
rg -q 'switchBackToHomeFromDownloads' "$APP" || { echo "FAIL: 缺少返回主页方法"; exit 1; }
rg -q 'RDDownloadsBackButton' "$APP" || { echo "FAIL: 返回按钮缺少标识"; exit 1; }

# 页面标题
rg -q '@"下载列表"' "$APP" || { echo "FAIL: 缺少下载列表标题"; exit 1; }

# 四个筛选状态
for sym in RDDownloadFilterAll RDDownloadFilterActive RDDownloadFilterSucceeded RDDownloadFilterFailed; do
  rg -q "$sym" "$APP" || { echo "FAIL: 缺少筛选状态 $sym"; exit 1; }
done
for label in "全部" "下载中" "已成功" "已失败"; do
  rg -qF "$label" "$APP" || { echo "FAIL: 缺少筛选按钮文案 $label"; exit 1; }
done

# 列表使用 NSTableView + 自定义行
rg -q 'NSTableView\s+\*\s*downloadsTable' "$APP" || { echo "FAIL: 缺少 downloadsTable"; exit 1; }
rg -q 'RDDownloadRowCellView' "$APP" || { echo "FAIL: 缺少下载行视图 RDDownloadRowCellView"; exit 1; }

# 文件名直接作为主文本，下载行不得显示资源分类徽章
if rg -q 'kindBadge|localizedNameForResourceKind' "$APP"; then
  echo "FAIL: 下载行仍保留资源类型称号或徽章" >&2
  exit 1
fi

# 进度条复用 RDThinProgressView
rg -q 'RDThinProgressView\s+\*\s*progressView' "$APP" || { echo "FAIL: 行内未使用 RDThinProgressView"; exit 1; }

# 行内显示四项下载指标
rg -q 'transferredBytes' "$APP" || { echo "FAIL: 未显示 transferredBytes"; exit 1; }
rg -q 'expectedContentLength' "$APP" || { echo "FAIL: 未显示 expectedContentLength"; exit 1; }
rg -q 'bytesPerSecond' "$APP" || { echo "FAIL: 未显示 bytesPerSecond"; exit 1; }
rg -q 'job\.progress' "$APP" || { echo "FAIL: 未显示 progress"; exit 1; }

# 空状态
rg -q 'RDDownloadsEmptyLabel' "$APP" || { echo "FAIL: 缺少空状态标识"; exit 1; }

# 横向锁定：无横向滚动条、无横向弹性、列宽跟随表格宽度、无固定 920 列宽
rg -q 'hasHorizontalScroller = NO' "$APP" || { echo "FAIL: 下载列表未禁用横向滚动条"; exit 1; }
rg -q 'horizontalScrollElasticity = NSScrollElasticityNone' "$APP" || { echo "FAIL: 下载列表未禁用横向弹性拖动"; exit 1; }
if rg -q 'col\.width = 920' "$APP"; then echo "FAIL: 仍使用固定 920px 列宽"; exit 1; fi
rg -q 'column\.maxWidth = width' "$APP" || { echo "FAIL: 列宽未跟随表格宽度"; exit 1; }

# 实时更新：高频回调合并 + 可见行原位刷新 + 整表重建时保留选中/滚动
rg -q 'scheduleDownloadsRefresh' "$APP" || { echo "FAIL: 缺少实时刷新调度"; exit 1; }
rg -q 'reloadDataForRowIndexes:' "$APP" || { echo "FAIL: 未使用可见行原位刷新"; exit 1; }
rg -q 'downloadsRenderedIdentifiers' "$APP" || { echo "FAIL: 缺少行顺序快照（筛选归属变化检测）"; exit 1; }
rg -q 'downloadsListDirtyWhileHidden' "$APP" || { echo "FAIL: 页面隐藏期间未记脏"; exit 1; }

# 操作按钮保留
for action in downloadsPauseTapped downloadsResumeTapped downloadsRetryTapped downloadsCancelTapped downloadsRevealTapped; do
  rg -q "$action" "$APP" || { echo "FAIL: 缺少行内操作 $action"; exit 1; }
done

# enqueuedAt 类型防护（旧记录/注入值不得让时间比较崩溃）
rg -q 'isKindOfClass:\[NSDate class\]' "$APP" || { echo "FAIL: 弱化判断缺少 NSDate 类型防护"; exit 1; }


echo "PASS: 下载列表页面静态检查通过（容器、导航、筛选、列表行、进度条、指标、操作）"
