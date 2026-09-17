#!/usr/bin/env python3
"""PROJECT_VERSION.json 的唯一读写工具（修复轮数唯一来源，规则见根目录 AGENTS.md）。

用法：
  project-version.py read-round      打印 fixRound（必须是 0 或正整数，否则报错退出 1）
  project-version.py read-last       打印 lastReleaseVersion（未设置为空串）
  project-version.py read-digest     打印 lastRelease.digest（未记录为空串）
  project-version.py write R L [D]   原子写入：fixRound=R、lastReleaseVersion=L；
                                     D 提供且非空时记录 lastRelease.digest，
                                     D 省略或为空时删除 lastRelease 记录

键顺序固定（fixRound、lastReleaseVersion、lastRelease），2 空格缩进、末尾换行，
保证同一状态在任何机器上写出的文件字节一致。本工具不使用时间、随机数或环境信息。
"""
import json
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "PROJECT_VERSION.json")


def load():
    try:
        with open(PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        sys.stderr.write("FAIL: 缺少 %s（修复轮数唯一来源，属于项目永久记录，不得删除）\n" % PATH)
        raise SystemExit(1)
    except ValueError as e:
        sys.stderr.write("FAIL: %s 不是合法 JSON：%s\n" % (PATH, e))
        raise SystemExit(1)


def check_round(v):
    if not isinstance(v, int) or isinstance(v, bool) or v < 0:
        sys.stderr.write("FAIL: fixRound 必须是非负整数，当前：%r\n" % (v,))
        raise SystemExit(1)
    return v


def main():
    args = sys.argv[1:]
    if not args:
        sys.stderr.write(__doc__)
        return 2
    cmd = args[0]
    if cmd == "read-round":
        print(check_round(load().get("fixRound")))
    elif cmd == "read-last":
        v = load().get("lastReleaseVersion", "")
        print(v if isinstance(v, str) else "")
    elif cmd == "read-digest":
        record = load().get("lastRelease")
        d = record.get("digest", "") if isinstance(record, dict) else ""
        print(d if isinstance(d, str) else "")
    elif cmd == "write":
        if len(args) < 3:
            sys.stderr.write("FAIL: write 需要 fixRound 与 lastReleaseVersion 两个参数\n")
            return 2
        try:
            round_ = check_round(int(args[1]))
        except ValueError:
            sys.stderr.write("FAIL: fixRound 必须是整数：%r\n" % (args[1],))
            return 2
        last = args[2]
        digest = args[3] if len(args) > 3 and args[3] else ""
        data = {"fixRound": round_, "lastReleaseVersion": last}
        if digest:
            data["lastRelease"] = {"digest": digest}
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PATH), prefix=".PROJECT_VERSION.", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
                f.write("\n")
            os.replace(tmp, PATH)
        except BaseException:
            if os.path.exists(tmp):
                os.unlink(tmp)
            raise
    else:
        sys.stderr.write("FAIL: 未知子命令：%r\n" % (cmd,))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
