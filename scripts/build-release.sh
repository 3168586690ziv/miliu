#!/bin/bash
# 正式发布构建入口（薄包装：转发给 scripts/build.sh，版本规则见根目录 AGENTS.md）。
# 用法：bash scripts/build-release.sh [--release-fix] [输出 .app 路径]
#   --release-fix：用户确认"完成一轮修复并产出可安装测试版本"时才使用，
#   同一轮（src 未变）重复执行不重复递增；构建失败自动恢复计数。
set -euo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/build.sh" "$@"
