#!/usr/bin/env python3
# 行级时间轴 E2E 专用受控下载源。
#   · 只绑定 127.0.0.1，不访问任何外部网络
#   · 单文件、固定 Content-Length、按固定速率限速（默认约 1.5 MB/s）
#   · 故意不声明 Accept-Ranges：迫使生产代码走单连接，进度可预测
# 用法: python3 e2e_test_server.py [总字节数] [总秒数]
# 首行输出 PORT=<端口>，供 shell 解析。
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOTAL = int(sys.argv[1]) if len(sys.argv) > 1 else 20 * 1024 * 1024
SECONDS = float(sys.argv[2]) if len(sys.argv) > 2 else 14.0
CHUNK = 64 * 1024
FTYP = b'\x00\x00\x00\x1cftypmp42\x00\x00\x00\x00mp42isomavc1'


def body():
    b = bytearray(TOTAL)
    b[0:min(len(FTYP), TOTAL)] = FTYP[0:min(len(FTYP), TOTAL)]
    return bytes(b)


BODY = body()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        sys.stderr.write("%s\n" % (args[0] % args[1:]))
        sys.stderr.flush()

    def _headers(self):
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str(TOTAL))
        self.send_header('Cache-Control', 'no-store')
        # 刻意不发 Accept-Ranges / 不处理 Range → 能力探测判定不支持分段
        self.end_headers()

    def do_HEAD(self):
        self._headers()

    def do_GET(self):
        self._headers()
        delay = SECONDS / max(1.0, (TOTAL + CHUNK - 1) // CHUNK)
        sent = 0
        try:
            while sent < TOTAL:
                n = min(CHUNK, TOTAL - sent)
                self.wfile.write(BODY[sent:sent + n])
                self.wfile.flush()
                sent += n
                if sent < TOTAL:
                    time.sleep(delay)
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print("PORT=%d" % srv.server_address[1], flush=True)
    sys.stderr.write("e2e server: %d bytes over ~%.1fs (single connection)\n" % (TOTAL, SECONDS))
    sys.stderr.flush()
    srv.serve_forever()


if __name__ == '__main__':
    main()
