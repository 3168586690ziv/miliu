#!/bin/bash
# 【已废弃，保留此文件仅为引导旧入口】修复轮数不再允许脱离构建单独递增。
# 旧流程（先手动递增计数、再构建）已删除，避免出现"递增了但构建失败"或重复递增。
#
# 现行规则（见根目录 AGENTS.md）：
#   · 修复轮数唯一来源：项目根目录 PROJECT_VERSION.json
#   · 普通构建（不递增）：bash scripts/build.sh
#   · 正式发布（构建成功后递增一次，失败自动恢复）：
#       bash scripts/build.sh --release-fix
#       bash scripts/build-release.sh --release-fix
set -euo pipefail
echo "FAIL: bump-fix-round.sh 已废弃；请使用 bash scripts/build.sh --release-fix（详见 AGENTS.md）" >&2
exit 1
