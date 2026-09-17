#!/usr/bin/env python3
# build/ui-probe/ui_audit.py — 黑盒几何/文本审计（配合 AXProbe 使用）
# 用法:
#   ui_audit.py <app路径> panes            # 打印左列表宽度/右侧详情提示宽度（用于比例档位验收）
#   ui_audit.py <app路径> audit [depth]    # 越界 + 重叠审计（黑盒，只看 AX 读回的坐标）
#                                           # 会按 NSScrollView 的裁剪规则把滚动区内容裁到
#                                           # 可见区，再判越界/重叠；被裁掉的内容必须真的有
#                                           # 滚动条可达，否则记为 UNREACHABLE（真缺陷）。
#   ui_audit.py <app路径> texts            # 打印所有 AXStaticText 的文本（状态文案/标题验收）
#   ui_audit.py <app路径> element <文本>   # 打印包含该文本的元素及其坐标
import re
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
LINE = re.compile(
    r'^(?P<indent>\s*)(?P<role>AX\w+)'
    r'(?: id=(?P<id>\S+))?'
    r'(?: title="(?P<title>[^"]*)")?'
    r'(?: value="(?P<value>[^"]*)")?'
    r'(?: desc="(?P<desc>[^"]*)")?'
    r'(?:\s+@ x=(?P<x>-?[\d.]+) y=(?P<y>-?[\d.]+) w=(?P<w>-?[\d.]+) h=(?P<h>-?[\d.]+))?'
    r'(?:\s+scrollers=v(?P<sv>[01]) h(?P<sh>[01]))?\s*$'
)


def dump(app, depth=8):
    out = subprocess.run([os.path.join(HERE, 'AXProbe'), app, 'tree', str(depth)],
                         capture_output=True, text=True).stdout
    nodes = []
    for raw in out.split('\n'):
        if '@' not in raw and not raw.strip().startswith('AX'):
            continue
        m = LINE.match(raw)
        if not m:
            continue
        d = m.groupdict()
        node = {
            'depth': len(d['indent']) // 2 if d['indent'] else 0,
            'role': d['role'], 'id': d['id'] or '', 'title': d['title'] or '',
            'value': d['value'] or '', 'desc': d['desc'] or '',
            'frame': None,
            'scrollers': (int(d['sv']) if d['sv'] is not None else None,
                          int(d['sh']) if d['sh'] is not None else None),
        }
        if d['x'] is not None:
            node['frame'] = tuple(float(d[k]) for k in ('x', 'y', 'w', 'h'))
        nodes.append(node)
    # 建立父子关系（按缩进）
    stack = []
    for i, n in enumerate(nodes):
        while stack and nodes[stack[-1]]['depth'] >= n['depth']:
            stack.pop()
        n['idx'] = i
        n['pidx'] = stack[-1] if stack else None
        stack.append(i)
    return nodes


def label(n):
    txt = n['title'] or n['value'] or n['desc'] or n['id'] or n['role']
    return f"{n['role']}{'#' + n['id'] if n['id'] else ''} “{txt[:40]}”"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    app, cmd = sys.argv[1], sys.argv[2]
    nodes = dump(app, int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3].isdigit() else 8)
    win = next((n for n in nodes if n['role'] == 'AXWindow' and n['frame']), None)

    if cmd == 'panes':
        sa = next((n for n in nodes if n['role'] == 'AXScrollArea' and n['frame']), None)
        hint = next((n for n in nodes if n['value'] == '点击左侧资源查看详情' and n['frame']), None)
        if win:
            print(f"WINDOW {win['frame'][2]:.1f}x{win['frame'][3]:.1f}")
        if sa:
            print(f"LEFT_PANE(列表) x={sa['frame'][0]:.1f} w={sa['frame'][2]:.1f}")
        if hint:
            # 空状态提示按右面板宽度居中铺满：w≈右面板宽，x≈右面板左边
            print(f"RIGHT_PANE(内容) x={hint['frame'][0]:.1f} w={hint['frame'][2]:.1f}")
        return 0

    if cmd == 'texts':
        for n in nodes:
            if n['role'] == 'AXStaticText' and (n['value'] or n['title']):
                f = n['frame']
                pos = f" @ x={f[0]:.0f} y={f[1]:.0f} w={f[2]:.0f} h={f[3]:.0f}" if f else ''
                print(f"TEXT “{n['value'] or n['title']}”{pos}")
        return 0

    if cmd == 'element':
        needle = sys.argv[3]
        hit = 0
        for n in nodes:
            blob = f"{n['title']}{n['value']}{n['desc']}{n['id']}"
            if needle in blob:
                f = n['frame']
                pos = f" @ x={f[0]:.1f} y={f[1]:.1f} w={f[2]:.1f} h={f[3]:.1f} (maxX={f[0]+f[2]:.1f} maxY={f[1]+f[3]:.1f})" if f else ' @(无坐标)'
                print(f"ELEM {label(n)}{pos}")
                hit += 1
        print(f"HITS {needle} = {hit}")
        return 0 if hit else 1

    if cmd == 'audit':
        if not win:
            print('AUDIT-FAIL 未读到窗口')
            return 1
        wx, wy, ww, wh = win['frame']
        # 父子索引（缩进即层级）—— 越界/重叠判定都要先用祖先链做滚动裁剪
        stack = []
        for i, n in enumerate(nodes):
            while stack and nodes[stack[-1]]['depth'] >= n['depth']:
                stack.pop()
            n['pidx'] = stack[-1] if stack else None
            stack.append(i)

        def is_ancestor(ai, bi):
            """ai 是否为 bi 的祖先（按索引比较）"""
            p = nodes[bi]['pidx']
            while p is not None:
                if p == ai:
                    return True
                p = nodes[p]['pidx']
            return False

        def visible(i):
            """元素被滚动祖先裁剪后的可见 rect（AppKit 的 NSScrollView 就是这么裁的）。

            AX 会如实报出**未裁剪**的文档坐标，所以滚动区里被滚出去的内容本该"越界"，
            直接照搬会误判。这里按同一套裁剪规则求交，并额外统计：
              · 需要滚动条才能看全的轴（被裁掉了）→ 该轴必须真的有滚动条，否则内容不可达 = 真越界；
              · 裁剪后为空 = 完全滚出可视区，不算越界，但要计入「需滚动才可见」。
            返回 (可见 rect 或 None, 缺垂直滚动条, 缺水平滚动条, 被裁剪)。
            """
            r = nodes[i]['frame']
            need_v = need_h = False
            have_v = have_h = False
            clipped = False
            for a in ancestors_of(i):
                sa = nodes[a]
                if sa['role'] != 'AXScrollArea' or not sa['frame']:
                    continue
                sx, sy, sw, sh = sa['frame']
                over_v = r[1] < sy - 0.5 or r[1] + r[3] > sy + sh + 0.5
                over_h = r[0] < sx - 0.5 or r[0] + r[2] > sx + sw + 0.5
                if over_v or over_h:
                    clipped = True
                    need_v = need_v or over_v
                    need_h = need_h or over_h
                if sa['scrollers']:
                    have_v = have_v or bool(sa['scrollers'][0])
                    have_h = have_h or bool(sa['scrollers'][1])
                x0, y0 = max(r[0], sx), max(r[1], sy)
                x1, y1 = min(r[0] + r[2], sx + sw), min(r[1] + r[3], sy + sh)
                r = (x0, y0, x1 - x0, y1 - y0)
                if r[2] <= 0 or r[3] <= 0:
                    return None, (need_v and not have_v), (need_h and not have_h), True
            return r, (need_v and not have_v), (need_h and not have_h), clipped

        def ancestors_of(i):
            p = nodes[i]['pidx']
            while p is not None:
                yield p
                p = nodes[p]['pidx']

        # 窗口子树内、有实际尺寸的元素（菜单栏/菜单项排除）。
        # AXScrollBar 是 AppKit 自己摆的滚动条 chrome：它坐在滚动区域边缘，坐标会因 AX
        # 取整比容器宽 1pt，且它的存在性另有单独校验（见 visible() 的 scrollers），
        # 因此不参与「越界」判定，避免用取整误差制造假缺陷。
        cand = [n for n in nodes
                if n['frame'] and n['frame'][2] > 0 and n['frame'][3] > 0
                and n['role'] not in ('AXWindow', 'AXMenu', 'AXMenuItem', 'AXMenuBar', 'AXMenuBarItem',
                                      'AXScrollBar')
                and (n['idx'] == win['idx'] or is_ancestor(win['idx'], n['idx']))]
        # AX 坐标是整数四舍五入（实测窗口右边界会差 1px），留 2px 容差再判定越界
        TOL = 2.0
        out, unreachable, scrolled_away = [], [], []
        for n in cand:
            rect, miss_v, miss_h, clipped = visible(n['idx'])
            if miss_v or miss_h:
                unreachable.append((n, miss_v, miss_h))
                continue
            if rect is None:
                scrolled_away.append(n)
                continue
            if not (wx - TOL <= rect[0] and rect[1] >= wy - TOL
                    and rect[0] + rect[2] <= wx + ww + TOL
                    and rect[1] + rect[3] <= wy + wh + TOL):
                out.append(n)
        print(f"窗口子树 {len(cand)} 个有尺寸元素；越界 {len(out)} 个；"
              f"被滚动裁剪但滚动条可达 {len(scrolled_away)} 个；滚动条缺失导致不可达 {len(unreachable)} 个")
        for n in out:
            print(f"  OUT-OF-BOUNDS {label(n)} @ {n['frame']}")
        for n, mv, mh in unreachable:
            print(f"  UNREACHABLE {label(n)} @ {n['frame']} 缺滚动条 v={int(mv)} h={int(mh)}")
        for n in scrolled_away:
            print(f"  SCROLLED-OUT(可达) {label(n)} @ {n['frame']}")

        # 结构性容器与滚动条在 AX 树里是同级，真实语义上互相包含/并列，
        # 重叠判定只针对“内容控件”（文本/按钮/下拉/输入框）。
        STRUCT = {'AXTable', 'AXRow', 'AXCell', 'AXColumn', 'AXScrollBar', 'AXScrollArea', 'AXGroup', 'AXImage'}
        content = [n for n in cand if n['role'] not in STRUCT]
        ov = 0
        for i in range(len(content)):
            for j in range(i + 1, len(content)):
                a, b = content[i], content[j]
                if is_ancestor(a['idx'], b['idx']) or is_ancestor(b['idx'], a['idx']):
                    continue
                ra = visible(a['idx'])[0]
                rb = visible(b['idx'])[0]
                if ra is None or rb is None:
                    continue      # 至少一方完全滚出可视区 → 画面上不可能重叠
                ax, ay, aw, ah = ra
                bx, by, bw, bh = rb
                ix, iy = max(ax, bx), max(ay, by)
                jx, jy = min(ax + aw, bx + bw), min(ay + ah, by + bh)
                if jx - ix > 0.5 and jy - iy > 0.5:
                    ov += 1
                    print(f"  OVERLAP {label(a)} × {label(b)} 重合 x={ix:.1f}..{jx:.1f} y={iy:.1f}..{jy:.1f} 面积={(jx-ix)*(jy-iy):.0f}")
        bad = len(out) + len(unreachable) + ov
        print(f"AUDIT 越界={len(out)} 不可达={len(unreachable)} 重叠={ov} → {'通过' if not bad else '不通过'}")
        return 0 if not bad else 1

    print(f'未知子命令 {cmd}')
    return 2


if __name__ == '__main__':
    sys.exit(main())
