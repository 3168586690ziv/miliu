#!/usr/bin/env python3
"""统计 src/ 下生产代码的物理行数（版本号第一段的唯一来源）。

规则（稳定、可重复，任何人执行结果相同）：
  · 目录：src/
  · 扩展名：.m .h .mm .c .cc .cpp .swift
  · 排除：build/ tests/ outputs/ third_party/ .git/ DerivedData/ 及常见临时目录
  · 物理行数：空行、注释行全部计入；文件末尾无换行的最后一行也计入
  · 只输出一个十进制整数（无其它文字），便于脚本直接取值
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
EXTS = {".m", ".h", ".mm", ".c", ".cc", ".cpp", ".swift"}
SKIP_DIRS = {"build", "tests", "outputs", "third_party", "DerivedData",
             ".git", ".svn", "tmp", "temp", "work", "node_modules"}


def count_physical_lines(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data:
        return 0
    lines = data.count(b"\n")
    if not data.endswith(b"\n"):
        lines += 1  # 末行没有换行符时仍算一行
    return lines


def main():
    if not os.path.isdir(SRC):
        sys.stderr.write("FAIL: 找不到源码目录 %s\n" % SRC)
        return 1
    total = 0
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if os.path.splitext(name)[1] in EXTS:
                total += count_physical_lines(os.path.join(dirpath, name))
    print(total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
