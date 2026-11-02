"""本机更新联调用的假发布源（只监听 127.0.0.1）。

用法：py -3 tool/update_test_server.py <端口> <zip 路径> [新版本号]
应用用 --dart-define=DYMUSE_UPDATE_API=http://127.0.0.1:<端口>/api/latest 与
DYMUSE_UPDATE_BASE=http://127.0.0.1:<端口>/dl 编译。安装包被下载过一次后，清单改回
当前版本，避免更新后的应用反复提示。
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
zip_path = sys.argv[2]
new_version = sys.argv[3] if len(sys.argv) > 3 else '9.9.9'
name = 'Dymuse-windows-x64.zip'
data = open(zip_path, 'rb').read()
state = {'downloaded': False}
tag = f'v{new_version}'


def manifest():
    version = '0.2.0' if state['downloaded'] else new_version
    return {
        'version': version,
        'build': 2,
        'notes': '联调用的假更新。\n- 下载并校验安装包\n- 退出后覆盖并重启',
        'assets': {
            'windows-x64': {
                'name': name,
                'size': len(data),
                'sha256': hashlib.sha256(data).hexdigest(),
            }
        },
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(self.address_string(), fmt % args, flush=True)

    def send(self, body, ctype):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        base = f'http://127.0.0.1:{port}'
        if self.path.startswith('/api/latest'):
            release = {
                'tag_name': tag,
                'prerelease': False,
                'body': '假发布',
                'assets': [
                    {'name': 'latest.json', 'browser_download_url': f'{base}/dl/{tag}/latest.json'}
                ],
            }
            self.send(json.dumps(release).encode(), 'application/json')
        elif self.path == f'/dl/{tag}/latest.json':
            self.send(json.dumps(manifest()).encode(), 'application/json')
        elif self.path == f'/dl/{tag}/{name}':
            self.send(data, 'application/zip')
            state['downloaded'] = True
        else:
            self.send_response(404)
            self.end_headers()


HTTPServer(('127.0.0.1', port), Handler).serve_forever()
