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
for label in "全部" "下载中" "已成功" "未完成"; do   # 第44轮「已失败→未完成」改名同步（此前断言靠清除框文案巧合通过，意图已失效）
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
# 页面隐藏期间不刷新；重新进入页面时无条件全量同步。
# 2026-10-13 第 41 轮：原断言守的是 downloadsListDirtyWhileHidden，而该标志位
# **只写不读**（4 处写、0 处读，页面进入走的是 showDownloads → refreshDownloadsList
# 无条件全量同步，行为一直是对的）——断言于是变成守一个没人读的位。已删该位，
# 断言改为直接守真实机制：隐藏早退 + 进入页面全量同步，并反向禁止标志位回流。
rg -q 'if \(self\.downloadsPage\.hidden\) return;' "$APP" || { echo "FAIL: 隐藏期间刷新调度缺少早退"; exit 1; }
if rg -q 'downloadsListDirtyWhileHidden' "$APP"; then
  echo "FAIL: 仍残留只写不读的 downloadsListDirtyWhileHidden"; exit 1
fi
rg -U -q 'showDownloads:\(id\)sender \{[^}]*refreshDownloadsList' "$APP" || { echo "FAIL: 进入下载页未全量同步"; exit 1; }

# 预计剩余时间必须真接到下载行（2026-10-13 第 42 轮）：DownloadManager 每轮采样都在算
# estimatedRemainingSeconds，且 formatRemainingSeconds: 也早已写好——但两者此前**都没有
# 任何调用点**，界面上永远看不到「还要多久」（数据、格式化器、行渲染三者都在，只差接线）。
# 断言守**真实调用点**（注释不能顶替 —— 首版只 grep 字段名，注释即可满足，属假绿，已收紧）：
# 格式化器必须被 job 的估算值调用，且它不能只剩定义。
rg -q 'formatRemainingSeconds:\(NSInteger\)job\.estimatedRemainingSeconds' "$APP" || { echo "FAIL: 下载行未用估算剩余时间调用格式化器（有数据无出口）"; exit 1; }
n_fmt=$(rg -c 'formatRemainingSeconds' "$APP" 2>/dev/null || echo 0)
[ "${n_fmt:-0}" -ge 2 ] || { echo "FAIL: formatRemainingSeconds 只有定义、没有调用点（有数据无出口）"; exit 1; }

# 操作按钮保留
for action in downloadsPauseTapped downloadsResumeTapped downloadsRetryTapped downloadsCancelTapped downloadsRevealTapped; do
  rg -q "$action" "$APP" || { echo "FAIL: 缺少行内操作 $action"; exit 1; }
done

# 时间比较的 NSDate 类型防护（旧记录/注入值不得让排序崩掉）。
# 2026-10-12 第 36 轮：防护原先挂在 shouldWeakenJob 上，而该轮把行内弱化判据整体
# 删除（主人点名「颜色深度统一 就是深色那一档」），防线随之迁到列表排序处。
# 断言同步到新落点，不再指向已删除的方法。
rg -q 'isKindOfClass:\[NSDate class\]' "$APP" || { echo "FAIL: 列表排序缺少 NSDate 类型防护"; exit 1; }

# 行内弱化必须彻底消失：不得残留恒假判据或恒假三元分支。
if rg -q 'shouldWeakenJob' "$APP"; then
  echo "FAIL: 仍残留 shouldWeakenJob（第 36 轮已取消行内弱化）"; exit 1
fi
if rg -q 'weakened \?' "$APP"; then
  echo "FAIL: 仍残留 weakened 三元分支（恒假死代码）"; exit 1
fi


echo "PASS: 下载列表页面静态检查通过（容器、导航、筛选、列表行、进度条、指标、操作、类型防护、无弱化残留）"
