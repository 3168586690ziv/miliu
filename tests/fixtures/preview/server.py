#!/usr/bin/env python3
# server.py — 预览测试用本地静态服务器（第 35 轮）
# 特性：Range/206 支持（AVPlayer 播 mp4 必需）、Referer 请求日志（预览方案断言依赖）、
#       LISTEN 就绪行、SIGTERM 优雅退出。
# 用法：python3 tests/fixtures/preview/server.py --port 8901 --root <夹具目录> [--log <文件>]
import argparse, http.server, socketserver, sys, threading, time, os, re, signal

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=8901)
parser.add_argument("--root", required=True)
parser.add_argument("--log")
args = parser.parse_args()
os.chdir(args.root)

log_file = open(args.log, "a") if args.log else None
log_lock = threading.Lock()

MIME = {".ts": "video/mp2t", ".m3u8": "application/vnd.apple.mpegurl",
        ".mp4": "video/mp4", ".key": "application/octet-stream"}


class H(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        line = "HTTP: %s %s Referer=%s" % (self.command, self.path, self.headers.get("Referer", "-"))
        with log_lock:
            print(line, flush=True)
            if log_file:
                log_file.write("%s %s\n" % (time.strftime("%H:%M:%S"), line))
                log_file.flush()

    def guess_type(self, path):
        return MIME.get(os.path.splitext(path)[1], "application/octet-stream")

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            self.send_error(404)
            return None
        if not os.path.isfile(path):
            self.send_error(404)
            return None
        size = os.path.getsize(path)
        ctype = self.guess_type(path)
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", "") or "")
        if m:
            start = int(m.group(1) or 0)
            end = int(m.group(2) or size - 1)
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.end_headers()
                return None
            import io
            self.send_response(206)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            with open(path, "rb") as f:
                f.seek(start)
                return io.BytesIO(f.read(end - start + 1))
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        return open(path, "rb")


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


srv = S(("127.0.0.1", args.port), H)
print("LISTEN %d" % args.port, flush=True)


def shutdown(signum, frame):
    threading.Thread(target=srv.shutdown).start()


signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)
srv.serve_forever()
