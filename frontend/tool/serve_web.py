import argparse
import http.client
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import SplitResult, unquote, urlsplit

FRONTEND_DIR = Path(__file__).resolve().parent.parent
BUILD_COMMAND = 'flutter build web --release --wasm --csp --no-web-resources-cdn'
API_PREFIX = '/api/'
API_TIMEOUT_SECS = 60
MAX_BODY_BYTES = 64 * 1024
HOP_BY_HOP_HEADERS = {
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'te', 'trailers',
    'transfer-encoding', 'upgrade', 'host', 'content-length',
}
CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript',
    '.mjs': 'text/javascript',
    '.wasm': 'application/wasm',
    '.json': 'application/json',
    '.css': 'text/css',
    '.png': 'image/png',
    '.ico': 'image/x-icon',
    '.svg': 'image/svg+xml',
    '.ttf': 'font/ttf',
    '.otf': 'font/otf',
    '.woff2': 'font/woff2',
    '.frag': 'text/plain',
    '.bin': 'application/octet-stream',
}


def uses_local_engine(a_root: Path) -> bool:
    bootstrap = a_root / 'flutter_bootstrap.js'
    return bootstrap.is_file() and '"useLocalCanvasKit":true' in bootstrap.read_text(encoding='utf-8')


def read_nginx_headers(a_nginx_conf: Path) -> list[tuple[str, str]]:
    pattern = re.compile(r'add_header\s+([\w-]+)\s+"([^"]*)"\s+always;')
    return pattern.findall(a_nginx_conf.read_text(encoding='utf-8'))


def make_handler(a_root: Path, a_api: SplitResult, a_headers: list[tuple[str, str]]):
    class WebHandler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def do_GET(self):
            self.dispatch()

        def do_HEAD(self):
            self.dispatch()

        def do_POST(self):
            self.dispatch()

        def do_PUT(self):
            self.dispatch()

        def do_PATCH(self):
            self.dispatch()

        def do_DELETE(self):
            self.dispatch()

        def dispatch(self):
            if urlsplit(self.path).path.startswith(API_PREFIX):
                self.proxy_api()
            else:
                self.serve_static()

        def proxy_api(self):
            length = int(self.headers.get('Content-Length') or 0)
            if length > MAX_BODY_BYTES:
                self.send_error(413)
                return

            body = self.rfile.read(length) if length else None
            headers = {name: value for name, value in self.headers.items() if name.lower() not in HOP_BY_HOP_HEADERS}
            headers['X-Real-IP'] = self.client_address[0]
            headers.setdefault('X-Forwarded-Proto', 'http')

            connection = http.client.HTTPConnection(a_api.hostname, a_api.port, timeout=API_TIMEOUT_SECS)
            try:
                connection.request(self.command, self.path, body=body, headers=headers)
                response = connection.getresponse()
                payload = response.read()
            except OSError as error:
                self.log_error('backend %s unavailable: %s', a_api.geturl(), error)
                self.send_error(502, 'Backend unavailable')
                return
            finally:
                connection.close()

            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() not in HOP_BY_HOP_HEADERS:
                    self.send_header(name, value)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(payload)

        def serve_static(self):
            if self.command not in ('GET', 'HEAD'):
                self.send_error(405)
                return

            requested = (a_root / unquote(urlsplit(self.path).path).lstrip('/')).resolve()
            is_asset = requested.is_relative_to(a_root) and requested.is_file()
            file = requested if is_asset else a_root / 'index.html'
            data = file.read_bytes()

            self.send_response(200)
            self.send_header('Content-Type', CONTENT_TYPES.get(file.suffix, 'application/octet-stream'))
            self.send_header('Cache-Control', 'no-cache')
            for name, value in a_headers:
                self.send_header(name, value)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)

    return WebHandler


def main():
    parser = argparse.ArgumentParser(
        description='Serves the release web build like nginx in production: app routes fall back to index.html, /api goes to the backend.'
    )
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=5173)
    parser.add_argument('--api', default='http://localhost:3000')
    parser.add_argument('--root', default=str(FRONTEND_DIR / 'build' / 'web'))
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not (root / 'index.html').is_file():
        raise SystemExit(f'{root} has no index.html, build the app first: {BUILD_COMMAND}')
    if not uses_local_engine(root):
        raise SystemExit(f'{root} loads the Flutter engine from a CDN, which the production CSP blocks. Rebuild: {BUILD_COMMAND}')

    api = urlsplit(args.api)
    headers = read_nginx_headers(FRONTEND_DIR / 'nginx.conf')
    server = ThreadingHTTPServer((args.host, args.port), make_handler(root, api, headers))
    print(f'Serving {root} on http://{args.host}:{args.port}, {API_PREFIX} -> {api.geturl()}', flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()


if __name__ == '__main__':
    main()
