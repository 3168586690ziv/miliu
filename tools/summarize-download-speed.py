#!/usr/bin/env python3
"""summarize-download-speed.py — 100 站下载测速汇总与归因分流（第 36 轮）

输入：download-speed-run.sh 产出的 results.tsv
输出：按「时长档位 × 速度档位」交叉统计，并把每站归因到两类之一：

  (a) 网络层 —— 对方服务器限速 / CDN 节点问题：APP 无可优化空间。
      判据：分段已生效（segmented=1）且各段都在跑，但速率仍低；
            或首字节延迟极大（对方响应慢）。
  (b) 配置层 —— APP 通病：必须修。
      判据：本可分段却退化成单连接（acceptRanges 探测失败/被拒）、
            或走了 curl 回退栈（说明原生栈被拦）、
            或分段数远低于当前档位允许值、或整体失败但 curl 手工可取。

速度档位（B/s，用于人眼分档，不是判定阈值）：
  <100KB/s  极慢   100KB-1MB/s 慢   1-5MB/s 正常   5-15MB/s 良好   >=15MB/s 优秀
"""
import sys
import os
from collections import Counter, defaultdict

KB = 1024.0
MB = 1024.0 * 1024.0

SLOW_ABS = 100 * KB          # 极慢阈值
SLOW_LOW = 1 * MB            # 慢阈值
GOOD = 5 * MB                # 正常/良好分界
EXCELLENT = 15 * MB          # 优秀

# 配置层嫌疑：分段能力没被用上（可在本机复现的 APP 侧原因）
FALLBACK_SUSPECT = "回退栈"


def tier_of(duration_s: float) -> str:
    if duration_s <= 0:
        return "unknown"
    m = duration_s / 60.0
    if m < 5:
        return "0-5min"
    if m < 10:
        return "5-10min"
    if m < 20:
        return "10-20min"
    return "20min+"


def speed_bucket(bps: float) -> str:
    if bps <= 0:
        return "无速率"
    if bps < SLOW_ABS:
        return "极慢(<100KB/s)"
    if bps < SLOW_LOW:
        return "慢(100KB-1MB/s)"
    if bps < GOOD:
        return "正常(1-5MB/s)"
    if bps < EXCELLENT:
        return "良好(5-15MB/s)"
    return "优秀(>=15MB/s)"


def fmt_bps(bps: float) -> str:
    if bps <= 0:
        return "-"
    if bps >= MB:
        return f"{bps / MB:.2f} MB/s"
    if bps >= KB:
        return f"{bps / KB:.1f} KB/s"
    return f"{bps:.0f} B/s"


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: summarize-download-speed.py <results.tsv> [out.txt]")
        return 2
    path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None
    if not os.path.exists(path):
        print(f"FAIL: 结果文件不存在：{path}")
        return 1

    rows = []
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < len(header):
                continue
            rows.append(dict(zip(header, parts)))

    lines = []
    add = lines.append

    add("=" * 78)
    add(f"100 站下载测速汇总：{path}")
    add(f"样本数：{len(rows)}")
    add("=" * 78)
    add("")

    if not rows:
        add("无有效样本。")
    else:
        # ── 总体 ──
        stat_counter = Counter(r["stat"] for r in rows)
        ok = [r for r in rows if r["stat"] == "OK"]
        add("【总体结果】")
        for k, v in stat_counter.most_common():
            add(f"  {k:<10} {v:>4} 站")
        add("")

        speeds = sorted(float(r["avg_bps"]) for r in ok if float(r["avg_bps"]) > 0)
        if speeds:
            n = len(speeds)
            median = speeds[n // 2] if n % 2 else (speeds[n // 2 - 1] + speeds[n // 2]) / 2
            add("【速度分布（仅成功站）】")
            add(f"  中位 {fmt_bps(median)}    最低 {fmt_bps(speeds[0])}    最高 {fmt_bps(speeds[-1])}")
            add("")

        # ── 时长档位 × 速度档位 ──
        add("【时长档位 × 速度档位】")
        table = defaultdict(Counter)
        tiers = ["0-5min", "5-10min", "10-20min", "20min+", "unknown"]
        buckets = ["极慢(<100KB/s)", "慢(100KB-1MB/s)", "正常(1-5MB/s)", "良好(5-15MB/s)", "优秀(>=15MB/s)", "无速率"]
        for r in rows:
            t = r.get("tier") or tier_of(float(r.get("duration") or 0))
            b = speed_bucket(float(r.get("avg_bps") or 0))
            table[t][b] += 1
        head = "档位".ljust(11) + "".join(b.split("(")[0].rjust(10) for b in buckets) + "  合计".rjust(8)
        add(head)
        for t in tiers:
            if not table[t]:
                continue
            tot = sum(table[t].values())
            add(t.ljust(11) + "".join(str(table[t][b]).rjust(10) for b in buckets) + str(tot).rjust(6))
        add("")

        # ── 归因分流 ──
        add("【归因分流】")
        config_suspect, network_suspect, healthy = [], [], []
        for r in rows:
            bps = float(r.get("avg_bps") or 0)
            segmented = r.get("segmented") == "1"
            segments = int(r.get("segments") or 0)
            fallback = r.get("fallback") == "1"
            first_byte = float(r.get("first_byte") or 0)
            stat = r["stat"]
            url = r["url"]

            if stat == "OK" and bps >= SLOW_LOW:
                healthy.append((url, bps))
                continue
            # 配置层嫌疑：本可分段却单连接 / 走了回退栈 / 分段数异常少
            reasons = []
            if not segmented and stat == "OK":
                reasons.append("单连接（未用上分段）")
            if fallback:
                reasons.append(FALLBACK_SUSPECT)
            if segmented and segments <= 1:
                reasons.append("分段数=1")
            if stat in ("FAIL", "TIMEOUT"):
                reasons.append(f"下载{stat}")
            if reasons:
                config_suspect.append((url, bps, "; ".join(reasons), stat))
            else:
                # 分段正常但慢 + 首字节大 ⇒ 对方限速/节点
                network_suspect.append((url, bps, first_byte, stat))

        add(f"  ✅ 健康（≥1MB/s）      {len(healthy):>4} 站")
        add(f"  ⚠️  配置层嫌疑（需修） {len(config_suspect):>4} 站")
        add(f"  🌐 网络层（不可改）    {len(network_suspect):>4} 站")
        add("")

        if config_suspect:
            add("── 配置层嫌疑明细（按速率升序，前 30 条）──")
            for url, bps, why, stat in sorted(config_suspect, key=lambda x: x[1])[:30]:
                add(f"  {fmt_bps(bps):>12}  [{stat}] {why}")
                add(f"                {url}")
            add("")
        if network_suspect:
            add("── 网络层明细（按速率升序，前 20 条）──")
            for url, bps, fb, stat in sorted(network_suspect, key=lambda x: x[1])[:20]:
                add(f"  {fmt_bps(bps):>12}  首字节{fb:.2f}s  [{stat}]")
                add(f"                {url}")
            add("")

        # ── 分段能力统计（配置层最关键的单一指标）──
        seg_on = sum(1 for r in rows if r.get("segmented") == "1")
        fb_on = sum(1 for r in rows if r.get("fallback") == "1")
        add("【分段能力使用情况】")
        add(f"  走分段：{seg_on}/{len(rows)}    走 curl 回退：{fb_on}/{len(rows)}")
        if rows:
            add(f"  分段率：{100.0 * seg_on / len(rows):.1f}%")
        add("")

    text = "\n".join(lines) + "\n"
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(text)
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
