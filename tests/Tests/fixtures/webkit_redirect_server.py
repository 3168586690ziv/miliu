from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl, threading, sys
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        print('REQUEST port=%d path=%s' % (self.server.server_port, self.path), flush=True)
        if self.path in ('/start', '/upgrade', '/downgrade'):
            self.send_response(302)
            target = '/final'
            if self.path == '/upgrade': target = 'https://127.0.0.1:%d/final' % secure.server_port
            if self.path == '/downgrade': target = 'http://127.0.0.1:%d/downgrade-final' % plain.server_port
            self.send_header('Location', target)
            body = b''
        else:
            self.send_response(403 if self.path == '/failure' else 200)
            body = b'<html><head><title>redirect-fixture</title></head><body>fixture</body></html>'
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass
plain = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
secure = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
secure.socket = context.wrap_socket(secure.socket, server_side=True)
print('%d %d' % (plain.server_port, secure.server_port), flush=True)
threading.Thread(target=secure.serve_forever, daemon=True).start()
plain.serve_forever()
