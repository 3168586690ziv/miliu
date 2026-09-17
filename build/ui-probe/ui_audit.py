#!/usr/bin/env python3
# build/ui-probe/ui_audit.py — 黑盒几何/文本审计（配合 AXProbe 使用）
# 用法:
#   ui_audit.py <app路径> panes            # 打印左列表宽度/右侧详情提示宽度（用于比例档位验收）
#   ui_audit.py <app路径> audit [depth]    # 越界 + 重叠审计（黑盒，只看 AX 读回的坐标）
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
    r'(?:\s+@ x=(?P<x>-?[\d.]+) y=(?P<y>-?[\d.]+) w=(?P<w>-?[\d.]+) h=(?P<h>-?[\d.]+))?\s*$'
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
        # 只看窗口子树内、有实际尺寸的元素（菜单栏/菜单项排除）
        cand = [n for n in nodes
                if n['frame'] and n['frame'][2] > 0 and n['frame'][3] > 0
                and wy <= n['frame'][1] <= wy + wh and n['role'] not in ('AXWindow', 'AXMenu', 'AXMenuItem', 'AXMenuBar', 'AXMenuBarItem')]
        # AX 坐标是整数四舍五入（实测窗口右边界会差 1px），留 2px 容差再判定越界
        TOL = 2.0
        out = [n for n in cand if not (wx - TOL <= n['frame'][0] and n['frame'][1] >= wy - TOL
                                       and n['frame'][0] + n['frame'][2] <= wx + ww + TOL
                                       and n['frame'][1] + n['frame'][3] <= wy + wh + TOL)]
        print(f"窗口子树 {len(cand)} 个有尺寸元素；越界 {len(out)} 个")
        for n in out:
            print(f"  OUT-OF-BOUNDS {label(n)} @ {n['frame']}")
        # 重算父子索引（缩进即层级）
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
                ax, ay, aw, ah = a['frame']
                bx, by, bw, bh = b['frame']
                ix, iy = max(ax, bx), max(ay, by)
                jx, jy = min(ax + aw, bx + bw), min(ay + ah, by + bh)
                if jx - ix > 0.5 and jy - iy > 0.5:
                    ov += 1
                    print(f"  OVERLAP {label(a)} × {label(b)} 重合 x={ix:.1f}..{jx:.1f} y={iy:.1f}..{jy:.1f} 面积={(jx-ix)*(jy-iy):.0f}")
        print(f"AUDIT 越界={len(out)} 重叠={ov} → {'通过' if not out and not ov else '不通过'}")
        return 0 if (not out and not ov) else 1

    print(f'未知子命令 {cmd}')
    return 2


if __name__ == '__main__':
    sys.exit(main())
