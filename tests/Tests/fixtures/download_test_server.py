#!/usr/bin/env python3
# 本地隔离下载测试服务器：仅绑定 127.0.0.1，供下载完整性测试驱动真实
# NSURLSession 后端。覆盖：143 字节 HTML/垃圾 MP4、完整 MP4、截断响应
# （声明 1000 只发 143）、Range 0-0 探测、Referer 回显、重定向。
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FTYP = b'\x00\x00\x00\x1cftypmp42\x00\x00\x00\x00mp42isomavc1'

FULL_VIDEO_SIZE = 788493
# 跨实例目录归属用例专用资源：必须 ≥ 24MB 才会走生产分段路径（8 段），
# 且要慢到足以让第二个实例在传输在途时执行清理。
SLOW_TOTAL = 25_165_824
SLOW_SECONDS = 6.0
SLOW_CHUNK = 65536
HTML143 = (b'<!DOCTYPE html><html><head><title>403 Forbidden</title></head>'
           b'<body><h1>403 Forbidden</h1><!-- xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx -->'
           b'</body></html>')
assert len(HTML143) == 143, len(HTML143)
GARBAGE143 = bytes((i * 37 + 11) % 256 for i in range(143))


def mp4_body(total):
    body = bytearray(total)
    n = min(len(FTYP), total)
    body[0:n] = FTYP[0:n]
    return bytes(body)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def _send(self, code, headers, body):
        self.send_response(code)
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        p = self.path.split('?')[0]
        referer = self.headers.get('Referer', '')
        if p == '/html-error':
            self._send(200, {'Content-Type': 'text/html; charset=utf-8',
                             'Content-Length': str(len(HTML143))}, HTML143)
        elif p == '/garbage-mp4':
            self._send(200, {'Content-Type': 'video/mp4',
                             'Content-Length': str(len(GARBAGE143))}, GARBAGE143)
        elif p == '/full-video':
            body = mp4_body(FULL_VIDEO_SIZE)
            self._send(200, {'Content-Type': 'video/mp4',
                             'Content-Length': str(len(body)),
                             'Accept-Ranges': 'bytes'}, body)
        elif p == '/truncated-video':
            # 声明 1000 字节，只发送 143 字节后直接关闭连接（模拟当时的事故响应）。
            body = mp4_body(143)
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', '1000')
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
        elif p == '/slow-range-video':
            # 支持 Range 的慢速大文件（跨实例目录归属用例）。每个请求无论区间大小
            # 都控制在约 SLOW_SECONDS 秒内完成，使"传输在途"这件事对测试是确定的。
            start, end = 0, SLOW_TOTAL - 1
            rng = self.headers.get('Range', '')
            status = 200
            if rng.startswith('bytes='):
                spec = rng[len('bytes='):].split(',')[0].strip()
                a, _, b = spec.partition('-')
                try:
                    if a == '':
                        start = max(0, SLOW_TOTAL - int(b))
                    else:
                        start = int(a)
                        end = int(b) if b else SLOW_TOTAL - 1
                except ValueError:
                    start, end = 0, SLOW_TOTAL - 1
                if start >= SLOW_TOTAL:
                    self._send(416, {'Content-Range': 'bytes */%d' % SLOW_TOTAL,
                                     'Content-Length': '0'}, b'')
                    return
                end = min(end, SLOW_TOTAL - 1)
                status = 206
            length = end - start + 1
            headers = {'Content-Type': 'video/mp4',
                       'Content-Length': str(length),
                       'Accept-Ranges': 'bytes'}
            if status == 206:
                headers['Content-Range'] = 'bytes %d-%d/%d' % (start, end, SLOW_TOTAL)
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            body = mp4_body(SLOW_TOTAL)
            sent = 0
            delay = SLOW_SECONDS / max(1, (length + SLOW_CHUNK - 1) // SLOW_CHUNK)
            try:
                while sent < length:
                    n = min(SLOW_CHUNK, length - sent)
                    self.wfile.write(body[start + sent:start + sent + n])
                    self.wfile.flush()
                    sent += n
                    if sent < length:
                        time.sleep(delay)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif p == '/range-ok':
            self._send(206, {'Content-Type': 'video/mp4',
                             'Content-Range': 'bytes 0-0/788493',
                             'Content-Length': '1', 'Accept-Ranges': 'bytes'}, b'\x00')
        elif p == '/referer-echo':
            data = referer.encode('utf-8')
            self._send(200, {'Content-Type': 'text/plain',
                             'Content-Length': str(len(data))}, data)
        elif p == '/redirect-referer':
            self.send_response(302)
            self.send_header('Location', 'http://127.0.0.2:%d/referer-echo' % self.server.server_address[1])
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            self._send(404, {'Content-Type': 'text/plain', 'Content-Length': '9'},
                       b'not found')

    def do_HEAD(self):
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
