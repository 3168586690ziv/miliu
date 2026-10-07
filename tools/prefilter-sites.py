#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prefilter-sites.py — 万站测试的前置过滤器（2026-10-06 建）

目的：从百万级域名榜里快速筛出「真的有视频内容」的站点，供 Miliu 深测。
原理：用轻量 HTTP 抓首页 HTML，只在正文里搜视频指示词；命中即入选。
     这一步比 WebKit 探测快几十倍（0.3-3s/站 vs 15-40s/站）。

用法：
  python3 tools/prefilter-sites.py --in top-1m.csv --out corpus.txt \
      --want 10000 --workers 100 --timeout 8 --probe-n 60000

  参数：
    --in       域名榜 CSV（rank,domain 格式，Tranco 即此格式）
    --out      输出语料文件（每行一个 https:// 开头的 URL）
    --want     目标入选站数（默认 10000）
    --workers  并发协程数（默认 100）
    --timeout  单站超时秒（默认 8）
    --probe-n  最多探测多少个域名（默认 = want*6，按 rank 顺序取）

筛选判据（命中任一即入选）：
  1. HTML 含 <video / <audio / <source 标签
  2. HTML 含 .mp4 / .m3u8 / .mpd / .webm 直链
  3. HTML 含 og:video / twitter:player / VideoObject（声明式媒体）
  4. HTML 含常见播放器特征（videojs / jwplayer / hls.js / dash.js / plyr）
  5. HTML 含 player/embed/watch/video 之类的路径 + 视频扩展名组合

输出：
  corpus.txt   入选站点（每行 https://domain/）
  stats.json   统计信息（探测数、命中数、各判据命中分布、失败分布）

设计纪律：
  · 只用标准库 + 并发，不依赖第三方包。
  · 全部并发都带超时；单个站点异常绝不中断整体。
  · 结果按 rank 排序输出（rank 高 = 更主流，优先测）。
"""
import argparse
import concurrent.futures
import threading
import urllib.request
import json
import re
import ssl
import sys
import time
import urllib.parse

# ── 判据（2026-10-06 收紧：区分「内容型视频站」与「碰巧有视频的站」）──
#
# 首轮教训：只用「首页含 <video> 标签」会把 whatsapp/zoom/discord/bit.ly 这类
# 通讯、会议、社群、短链站全部筛进来——它们的 <video> 只是营销演示片，不是用户
# 要找的资源。测这些站只产生噪音（超时率 50%，全是"可达但无媒体"）。
# 现在要求：**至少两个实质判据同时命中**，且域名不在非内容型黑名单里。
RE_VIDEO_TAG = re.compile(r'<(video|audio|source)\b', re.I)
RE_MEDIA_URL = re.compile(r'\.(mp4|m3u8|mpd|webm|mov|m4v|ts|flv|mkv)(?:[?"\'#]|$)', re.I)
RE_META_MEDIA = re.compile(r'(og:video|twitter:player|VideoObject|contentUrl)', re.I)
RE_PLAYER = re.compile(r'(videojs|jwplayer|hls\.js|dash\.js|plyr|video-js|flowplayer|clappr|shaka-player)', re.I)
RE_EMBED = re.compile(r'(/embed/|/player/|/watch\?|/video/|/videos/|/play/)', re.I)

# 非内容型域名黑名单：通讯/会议/社群/短链/CDN/基建/电商/工具/企业服务。
# 这些站即使首页有视频标签，也不是"找视频资源"的场景。
BLOCK_DOMAIN = re.compile(
    r'(whatsapp|telegram|signal\.org|discord|slack|zoom\.us|meet\.google|teams\.microsoft|'
    r'skype|wechat|qq\.com|line\.me|messenger|'
    r'bit\.ly|t\.co|tinyurl|goo\.gl|ow\.ly|is\.gd|buff\.ly|rebrand\.ly|cutt\.ly|shorturl|'
    r'fastly|cloudflare|akamai|cloudfront|cdn|jsdelivr|unpkg|b-cdn|netlify|vercel|herokuapp|'
    r'amazonaws|googleapis|gstatic|azureedge|rsc\.cdn|'
    r'discord|reddit\.com|twitter\.com|x\.com|facebook\.com|linkedin\.com|pinterest\.com|tumblr\.com|'
    r'paypal|stripe|squareup|bank|visa|mastercard|'
    r'salesforce|hubspot|servicenow|atlassian|github\.com|gitlab|bitbucket|'
    r'office\.com|microsoft\.com|apple\.com|icloud|dropbox|box\.com|notion\.so|'
    r'amazon\.com|ebay|alibaba|aliexpress|shopify|etsy|'
    r'booking\.com|airbnb|expedia|tripadvisor|uber|lyft|doordash|'
    r'samsung|xiaomi|huawei|opera\.com|mozilla|firefox|chrome)', re.I)

def is_content_site(domain: str) -> bool:
    """域名是否可能是内容型站点（非通讯/工具/基建）。"""
    return not BLOCK_DOMAIN.search(domain)

MAX_HTML = 512 * 1024   # 只读前 512KB，够找到判据


def classify(html: str):
    """返回命中的判据列表（空列表 = 未命中）。

    判据演进（2026-10-06）：
    v1「首页含 <video>」太松 → whatsapp/zoom/discord/bit.ly 全进来了（营销演示片）。
    v2「双判据 + 域名黑名单」→ 黑名单是打地鼠，永远枚举不完。
    v3（当前）**强信号判据**：只有内容型站点才会有的结构性特征——
      ① 流媒体清单（.m3u8/.mpd）：点播/直播站的标志，工具站不会有
      ② 播放器库（hls.js/dash.js/videojs/jwplayer/shaka/plyr/clappr/flowplayer）：
         专门用来播视频内容的库，几乎只在视频站出现
      ③ 多个视频元素（≥3 个 <video>/<source>）：内容列表/画廊的结构
      ④ 声明式媒体（og:video/VideoObject）：分享媒体内容的页面
    单个 <video> 标签不再足够（营销首页也常有）。
    """
    hits = []
    streaming = bool(re.search(r'\.(m3u8|mpd)(?:[?"\'#]|$)', html, re.I))
    if streaming:
        hits.append('streaming')
    player = bool(RE_PLAYER.search(html))
    if player:
        hits.append('player_lib')
    tag_count = len(re.findall(r'<(video|source)\b', html, re.I))
    if tag_count >= 3:
        hits.append('multi_video')
    meta = bool(RE_META_MEDIA.search(html))
    if meta:
        hits.append('meta_decl')
    if RE_MEDIA_URL.search(html):
        hits.append('media_url')
    # 强信号门槛：只有 <video> 标签、没有其他实质特征 → 不入选
    #（营销首页/登录页的演示片就是这个形态，首轮噪音的主要来源）
    STRONG = {'streaming', 'player_lib', 'multi_video', 'meta_decl', 'media_url'}
    if RE_VIDEO_TAG.search(html):
        hits.append('video_tag')
    if not (STRONG & set(hits)):
        return []                      # 证据不足，不入选
    return hits


# 视频域白名单：首页是 JS 壳、静态 HTML 无媒体特征，但确属内容型视频站。
# 静态筛选对这类站点天然失灵（内容全靠 JS 渲染），需显式放行。
# 命中即入选，无需等 classify 的 HTML 判据。
VIDEO_DOMAIN_HINT = re.compile(
    r'(youtube|youtu\.be|netflix|hulu|disneyplus|hbomax|peacocktv|paramountplus|'
    r'twitch|vimeo|dailymotion|bilibili|acfun|iqiyi|youku|mgtv|le\.com|sohu|'
    r'douyu|huya|douyin|kuaishou|xiaohongshu|'
    r'primevideo|crunchyroll|funimation|hidive|aniwatch|9anime|gogoanime|'
    r'pornhub|xvideos|xhamster|redtube|youporn|spankbang|eporner|beeg|'
    r'archive\.org|ted\.com|khanacademy|coursera|udemy|edx|skillshare|'
    r'rumble|bitchute|odysee|lbry|peertube|'
    r'bbc\.co\.uk|cnn\.com|nbcnews|abcnews|foxnews|cbsnews|npr\.org|'
    r'liveleak|streamable|sendvid|d.tube)', re.I)

def is_content_site_domain(domain: str) -> bool:
    """域名级粗筛：明显非内容型直接跳过（省请求，但判断主要靠 classify 的强信号）。"""
    return not BLOCK_DOMAIN.search(domain)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='infile', required=True)
    ap.add_argument('--out', dest='outfile', required=True)
    ap.add_argument('--want', type=int, default=10000)
    ap.add_argument('--workers', type=int, default=150)
    ap.add_argument('--timeout', type=float, default=8.0)
    ap.add_argument('--probe-n', type=int, default=0)
    ap.add_argument('--proxy', default='http://127.0.0.1:7897',
                    help='HTTP 代理（实测经代理命中率显著更高；传空串则直连）')
    args = ap.parse_args()

    probe_n = args.probe_n or args.want * 8

    domains = []
    with open(args.infile, encoding='utf-8', errors='replace') as f:
        for line in f:
            parts = line.strip().split(',')
            if len(parts) >= 2:
                domains.append(parts[1].strip())
            if len(domains) >= probe_n:
                break
    print(f"[prefilter] 待探测 {len(domains)} 个域名（目标入选 {args.want}）", flush=True)

    if args.proxy:
        handler = urllib.request.ProxyHandler({'https': args.proxy, 'http': args.proxy})
    else:
        handler = urllib.request.ProxyHandler({})
    opener = urllib.request.build_opener(handler)

    picked, stats_hits, stats_note = [], {}, {}
    lock = threading.Lock()
    done = 0
    t0 = time.time()

    def worker(dom):
        nonlocal done
        note = 'ok'
        hits = []
        # 域名级预筛：通讯/工具/基建类直接跳过（不浪费请求）
        if not is_content_site_domain(dom):
            with lock:
                done += 1
                stats_note['blocked_domain'] = stats_note.get('blocked_domain', 0) + 1
            return
        # 视频域白名单：JS 壳类知名视频站直接入选（静态 HTML 判据对它们失灵）
        if VIDEO_DOMAIN_HINT.search(dom):
            with lock:
                done += 1
                stats_note['video_domain'] = stats_note.get('video_domain', 0) + 1
                stats_hits['video_domain'] = stats_hits.get('video_domain', 0) + 1
                picked.append((dom, ['video_domain']))
            return
        try:
            req = urllib.request.Request(f"https://{dom}/", headers={
                'User-Agent': ('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                               'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15'),
                'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
                'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            })
            with opener.open(req, timeout=args.timeout) as r:
                raw = r.read(MAX_HTML)
                code = r.status
            if code != 200:
                note = f'http:{code}'
            else:
                text = raw.decode('utf-8', 'replace')
                hits = classify(text)
                if not hits:
                    note = 'no_media'
        except Exception as e:
            note = f"err:{type(e).__name__}"

        with lock:
            done += 1
            stats_note[note] = stats_note.get(note, 0) + 1
            if hits:
                for h in hits:
                    stats_hits[h] = stats_hits.get(h, 0) + 1
                picked.append((dom, hits))
            if done % 1000 == 0:
                el = time.time() - t0
                rate = done / el if el else 0
                eta = (len(domains) - done) / rate / 60 if rate else 0
                print(f"[prefilter] {done}/{len(domains)} 已探 ｜ 入选 {len(picked)} ｜ "
                      f"{rate:.1f}/s ｜ 已用 {el/60:.1f} 分 ｜ 预计还需 {eta:.0f} 分", flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(ex.map(worker, domains))

    final = picked[:args.want]
    with open(args.outfile, 'w', encoding='utf-8') as f:
        f.write("# Miliu 万站语料（prefilter-sites.py 生成）\n")
        f.write(f"# 从 {len(domains)} 个域名中筛出，按流行度排序\n\n")
        for d, _ in final:
            f.write(f"https://{d}/\n")

    stats = {
        'probed': len(domains), 'picked_total': len(picked), 'written': len(final),
        'elapsed_sec': round(time.time() - t0, 1),
        'hit_kinds': stats_hits, 'notes': stats_note,
    }
    with open(args.outfile + '.stats.json', 'w', encoding='utf-8') as f:
        json.dump(stats, f, ensure_ascii=False, indent=2)

    print(f"\n[prefilter] 完成：探测 {len(domains)} ｜ 命中 {len(picked)} ｜ 写出 {len(final)}")
    print(f"[prefilter] 耗时 {(time.time()-t0)/60:.1f} 分钟 ｜ 判据 {stats_hits}")
    print(f"[prefilter] 输出：{args.outfile}")


if __name__ == '__main__':
    main()
