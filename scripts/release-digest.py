#!/usr/bin/env python3
"""计算"修复轮"内容摘要 —— --release-fix 判断"同一轮重复执行"的依据（不是版本号来源）。

摘要 = sha256( 按 src 内相对路径排序的每个生产代码文件（相对路径 + 文件内容 sha256）
             + src/Packaging/Info.plist 去掉两个版本键后的规范化内容 )

- 文件范围与 scripts/count-code-lines.py 完全一致：src/ 下
  .m .h .mm .c .cc .cpp .swift，排除 build/tests/outputs/third_party/.git/
  DerivedData 及临时目录（两处常量必须同步修改）
- 构建脚本会把版本号写回 src/Packaging/Info.plist 的 CFBundleShortVersionString /
  CFBundleVersion 两个键；摘要计算前剔除这两个键，因此"正式构建后（源码未改）
  再次执行 --release-fix"仍识别为同一轮，不会重复递增
- 只输出一个十六进制摘要；同一份 src 内容在任何机器、任何 AI、任何上下文下结果相同
"""
import hashlib
import json
import os
import plistlib
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
EXTS = {".m", ".h", ".mm", ".c", ".cc", ".cpp", ".swift"}
SKIP_DIRS = {"build", "tests", "outputs", "third_party", "DerivedData",
             ".git", ".svn", "tmp", "temp", "work", "node_modules"}
VERSION_KEYS = ("CFBundleShortVersionString", "CFBundleVersion")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if not os.path.isdir(SRC):
        sys.stderr.write("FAIL: 找不到源码目录 %s\n" % SRC)
        return 1
    parts = []
    for dirpath, dirnames, filenames in os.walk(SRC):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if os.path.splitext(name)[1] in EXTS:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, ROOT)
                parts.append("%s %s" % (rel, sha256_file(full)))
    # Sort the complete code entry list, not just each directory. Keep the
    # existing line format and append the normalized plist entry last.
    parts.sort(key=lambda entry: entry.rsplit(" ", 1)[0])
    plist_path = os.path.join(SRC, "Packaging", "Info.plist")
    if os.path.isfile(plist_path):
        with open(plist_path, "rb") as f:
            pl = plistlib.load(f)
        for key in VERSION_KEYS:
            pl.pop(key, None)
        normalized = json.dumps(pl, sort_keys=True, ensure_ascii=False,
                                separators=(",", ":")).encode("utf-8")
        parts.append("Info.plist " + hashlib.sha256(normalized).hexdigest())
    print(hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
