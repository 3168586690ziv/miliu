"""websocket_scan_server.py — WebSocket 帧媒体地址扫描夹具（第 44 轮）。

媒体地址**只出现在 WebSocket 文本帧里**，页面 HTML 从不包含、也从不请求它们：
  GET /                 HTML，内联 JS 连 ws://127.0.0.1:PORT/sig，binaryType=arraybuffer，
                        收帧后什么都不做（页面既不解析、也不请求任何媒体地址）
  GET /wsfail           HTML，另放一张普通图片 + 一次 fetch 接口（WebSocket 钩子失败场景的对照）
  GET /sig              WebSocket 升级；连上后依次推 5 条帧：
                          1) 文本 JSON：{"type":"init","sources":[{"file":"…/media/ws_only.mp4",…}]}
                          2) 文本裸 URL：…/media/ws_plain.webm
                          3) 文本 >2MB 填充帧（内含 …/media/filler.mp4，必须被长度闸挡住）
                          4) 二进制帧（opcode=2）：前 64KB 内含 …/media/ws_binary.m4v（应探到）
                          5) 二进制帧（opcode=2）：URL 被推到 70KB 偏移（超出 65536 字节闸，必须探不到）
  GET /api/control.json application/json —— 内嵌 …/static/control2.mp4（fetch_body 路径对照）
  GET /static/control.png  1x1 PNG（真实图片，供 <img> 路径）
  GET /media/*          小段二进制；这两个地址**一旦被 GET 就说明走了网络请求路径**，
                        测试据此断言日志里零 GET。

只依赖 Python 标准库：WebSocket 服务端用 socket + 手写握手（Sec-WebSocket-Accept）
+ 手写文本帧（FIN=1, opcode=1, 服务端不掩码），不引入任何第三方库。

stdout 第一行是端口号（由 websocket-scan.sh 读取），此后每行一条 "REQ <method> <path>"。
"""
import base64
import hashlib
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
FILLER_BYTES = 3 * 1024 * 1024          # 3MB > 注入脚本 2MB 字符串帧闸
PNG_1X1 = base64.b64decode(
    b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


def ws_frame(payload: bytes, opcode: int = 0x1) -> bytes:
    """服务端 → 客户端文本帧：FIN=1，不掩码。"""
    n = len(payload)
    head = bytes([0x80 | opcode])
    if n < 126:
        head += struct.pack("!B", n)
    elif n < 65536:
        head += struct.pack("!BH", 126, n)
    else:
        head += struct.pack("!BQ", 127, n)
    return head + payload


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # ---------- 路由 ----------
    def _base(self):
        return "http://127.0.0.1:%d" % self.server.server_port

    def _send(self, ctype, body):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _ws_root_page(self):
        base = self._base()
        page = ("""<!DOCTYPE html><html><head><meta charset="utf-8">"""
                """<title>websocket-scan-fixture</title></head><body><p>ws fixture</p><script>
try{var s=new WebSocket('ws://127.0.0.1:%d/sig');s.binaryType='arraybuffer';s.onmessage=function(){};}
catch(e){}
</script></body></html>""" % self.server.server_port)
        self._send("text/html; charset=utf-8", page.encode())

    def _ws_fail_page(self):
        # 普通图片 + fetch 接口：WebSocket 钩子被夹具脚本弄坏后，这两条路径必须照样工作。
        page = ("""<!DOCTYPE html><html><head><meta charset="utf-8">"""
                """<title>websocket-scan-fail-fixture</title></head><body>"""
                """<img id="ctl" src="/static/control.png" width="1" height="1"><script>
fetch('/api/control.json').then(function(r){return r.json();}).catch(function(){});
try{var s=new WebSocket('ws://127.0.0.1:%d/sig');s.onmessage=function(){};}
catch(e){}
</script></body></html>""" % self.server.server_port)
        self._send("text/html; charset=utf-8", page.encode())

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        base = self._base()
        if path == "/":
            self._ws_root_page()
        elif path == "/wsfail":
            self._ws_fail_page()
        elif path == "/sig":
            self._websocket_session()
        elif path == "/api/control.json":
            # 注意：注入脚本的 scanText 正则只认媒体扩展名（m3u8/mpd/mp4/webm/mov/
            # m4v/mkv/ts/flv），图片扩展名不在其中 —— 所以对照项必须用 mp4，
            # 用 .png 会得到一条恒假的「fetch_body 没工作」断言。
            self._send("application/json",
                       ('{"ok":true,"file":"%s/static/control2.mp4"}' % base).encode())
        elif path == "/static/control.png":
            self._send("image/png", PNG_1X1)
        elif path.startswith("/media/"):
            # 被请求到即失败信号：探测只登记帧内地址，绝不该来取它们。
            self._send("application/octet-stream", b"\x00" * 64)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    # ---------- WebSocket ----------
    def _websocket_session(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.wfile.flush()

        base = self._base()
        frames = [
            ws_frame(('{"type":"init","sources":[{"file":"%s/media/ws_only.mp4",'
                      '"label":"720p"}]}' % base).encode()),
            ws_frame(("%s/media/ws_plain.webm" % base).encode()),
            # 填充帧：整帧 > 2MB，内含 filler.mp4——长度闸必须拦住，否则它会变成垃圾资源条目。
            ws_frame(('pad:' + 'A' * FILLER_BYTES + ":%s/media/filler.mp4" % base).encode()),
            # 二进制帧：前 64KB 内的地址应被 TextDecoder 转文本后探到。
            ws_frame(("%s/media/ws_binary.m4v" % base).encode(), opcode=0x2),
            # 二进制帧：地址落在 70KB 偏移，超出 65536 字节读取闸，必须探不到。
            ws_frame((b"B" * 70000 + ("%s/media/ws_far_binary.m4v" % base).encode()), opcode=0x2),
        ]
        for f in frames:
            try:
                self.wfile.write(f)
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(0.05)
        # 留一点时间让页面读走全部帧，再收线（数据先于 FIN 送达）。
        time.sleep(1.5)
        self.close_connection = True

    def log_message(self, fmt, *args):
        sys.stdout.write("REQ %s %s\n" % (self.command, self.path))
        sys.stdout.flush()


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_port, flush=True)
server.serve_forever()
