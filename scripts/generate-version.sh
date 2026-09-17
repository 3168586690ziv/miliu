#!/bin/bash
# 生成构建期版本信息（幂等：重复执行不改变修复轮数，只重算代码行数）。
#
# 输出：
#   build/generated/RDGeneratedVersion.h  —— App 编译期读取的版本宏
#   build/generated/version.env           —— CODE_LINES / FIX_ROUND / DISPLAY_VERSION
# 并打印三行构建日志：
#   CODE_LINES=<数字>
#   FIX_ROUND=<数字>
#   DISPLAY_VERSION=v<数字>.<数字>
#
# 代码行数：scripts/count-code-lines.py 按固定规则统计 src/（见该脚本注释）。
# 修复轮数：项目根目录 PROJECT_VERSION.json 的 fixRound（唯一来源，本项目历史事实；
# 只读不写，递增只能由 scripts/build.sh --release-fix 在构建成功后执行一次）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/build/generated"

FIX_ROUND="$(python3 "$ROOT/scripts/project-version.py" read-round)"

CODE_LINES="$(python3 "$ROOT/scripts/count-code-lines.py")"
case "$CODE_LINES" in
  ''|*[!0-9]*) echo "FAIL: 代码行数统计结果非法：$CODE_LINES" >&2; exit 1 ;;
esac

DISPLAY_VERSION="v${CODE_LINES}.${FIX_ROUND}"

mkdir -p "$GEN"

write_if_changed() {
  local path="$1"
  local tmp="$path.tmp.$$"
  cat > "$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$path"
  fi
}

write_if_changed "$GEN/RDGeneratedVersion.h" <<EOF
// 本文件由 scripts/generate-version.sh 于构建时生成，请勿手工修改。
// 设置页显示的版本号、Info.plist 的版本字段都来自这里的同一次统计。
#ifndef RD_GENERATED_VERSION_H
#define RD_GENERATED_VERSION_H

#define RD_GENERATED_VERSION_STRING @"${DISPLAY_VERSION}"
#define RD_GENERATED_CODE_LINES ${CODE_LINES}
#define RD_GENERATED_FIX_ROUND ${FIX_ROUND}

#endif
EOF

write_if_changed "$GEN/version.env" <<EOF
CODE_LINES=${CODE_LINES}
FIX_ROUND=${FIX_ROUND}
DISPLAY_VERSION=${DISPLAY_VERSION}
EOF

printf 'CODE_LINES=%s\nFIX_ROUND=%s\nDISPLAY_VERSION=%s\n' "$CODE_LINES" "$FIX_ROUND" "$DISPLAY_VERSION"
