"""body_scan_server.py — 响应体扫描夹具服务器（2026-10-05 第 21 轮）。

媒体链接只存在于接口响应体中，页面本身从不请求这些媒体地址：
  GET /              HTML，onload 后 fetch /api/data.json、fetch /big.json、XHR /api/list
  GET /api/data.json application/json —— 内嵌 m3u8 与 mp4 链接（应被 fetch_body 扫出）
  GET /api/list      text/plain —— 内嵌 webm 链接（应被 xhr_body 扫出）
  GET /big.json      application/json —— 5MB 超 3MB 上限，内嵌 too-big.mp4（必须不出现）

链接 host 用 127.0.0.1:<port>：回环地址在夹具 URLPolicy 白名单内（外网不可解析域名
会被生产策略按 DNS 失败 fail-closed 拒绝，走不到「扫描贡献」的判定）。

打印 "PORT" 到 stdout（单行），由 body-scan.sh 读取。
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIG = 5 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    def _links(self):
        base = 'http://127.0.0.1:%d' % self.server.server_port
        return (base + '/stream/master.m3u8?token=abc123',
                base + '/clip/movie.mp4?range=0-999',
                base + '/media/clip2.webm',
                base + '/hidden/too-big.mp4')

    def _send(self, ctype, body):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        m3u8, mp4, webm, hidden = self._links()
        if self.path == '/':
            page = ("""<!DOCTYPE html><html><head><meta charset="utf-8"><title>body-scan-fixture</title></head>
<body><video src="/direct/v.mp4" width="1" height="1"></video><script>
fetch('/api/data.json').then(function(r){return r.json();}).catch(function(){});
var x=new XMLHttpRequest();x.open('GET','/api/list');x.send();
fetch('/big.json').then(function(r){return r.text();}).catch(function(){});
</script></body></html>""").encode()
            self._send('text/html', page)
        elif self.path == '/api/data.json':
            self._send('application/json',
                       ('{"ok":true,"url1":"%s","url2":"%s"}' % (m3u8, mp4)).encode())
        elif self.path == '/api/list':
            self._send('text/plain', ('first %s last' % webm).encode())
        elif self.path == '/big.json':
            # 真给 5MB（超过注入脚本 3MB 上限），验证超限响应体不被扫描
            filler = b'{"pad":"' + b'x' * BIG + (b'","url":"%s"}' % hidden.encode())
            self._send('application/json', filler)
        else:
            # 扫出的媒体链接不需要真的可达——探测只登记；这些路径 404 即可
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
