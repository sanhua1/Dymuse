import base64
import http.client
import http.server
import json
import os
import stat
import tempfile
import threading
import unittest
import urllib.parse
from http.server import ThreadingHTTPServer

import server


class FakeNetease(http.server.BaseHTTPRequestHandler):
    """假的网易云 API：扫码第一次回 801，第二次回 803 并带 Cookie。"""
    checks = 0

    def log_message(self, *args):
        pass

    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.route(urllib.parse.urlparse(self.path).path, {})

    def do_POST(self):
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get('Content-Length', 0))).decode())
        self.route(self.path.split('?')[0], {k: v[0] for k, v in form.items()})

    def route(self, path, form):
        if path == '/login/qr/key':
            return self.reply({'data': {'unikey': 'fake-key'}, 'code': 200})
        if path == '/login/qr/create':
            return self.reply({'data': {'qrimg': 'data:image/png;base64,AAAA'}, 'code': 200})
        if path == '/login/qr/check':
            FakeNetease.checks += 1
            if FakeNetease.checks == 1:
                return self.reply({'code': 801, 'cookie': ''})
            return self.reply({'code': 803, 'cookie': 'MUSIC_U=scanned-secret; Path=/;__csrf=csrf1; HTTPOnly;NMTID=n1;MUSIC_A=anon'})
        if path == '/user/account':
            if 'bad' in form.get('cookie', ''):
                return self.reply({'code': 200, 'account': None, 'profile': None})
            return self.reply({'code': 200, 'account': {'vipType': 11}, 'profile': {'nickname': '主人'}})
        if path == '/song/url/v1':
            trial = 'trial' in form.get('cookie', '')
            item = {'url': 'https://x/a.flac', 'level': 'lossless', 'type': 'flac', 'br': 900000,
                    'freeTrialInfo': {'start': 0} if trial else None}
            return self.reply({'code': 200, 'data': [item]})
        self.send_response(404)
        self.end_headers()


def basic(user, password):
    return 'Basic ' + base64.b64encode(f'{user}:{password}'.encode()).decode()


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        cls.fake = ThreadingHTTPServer(('127.0.0.1', 0), FakeNetease)
        threading.Thread(target=cls.fake.serve_forever, daemon=True).start()
        cls.fake_url = f'http://127.0.0.1:{cls.fake.server_address[1]}'

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.fake.shutdown()

    def setUp(self):
        self.state = tempfile.mkdtemp()
        server.STATE = self.state
        server.NETEASE_API = self.fake_url
        server._fails.clear()
        FakeNetease.checks = 0

    def call(self, method, path, auth=None, body=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        headers = {'Authorization': auth} if auth else {}
        data = json.dumps(body) if body is not None else ('' if method == 'POST' else None)
        if body is not None:
            headers['Content-Type'] = 'application/json'
        conn.request(method, path, data, headers)
        res = conn.getresponse()
        raw = res.read()
        try:
            return res.status, json.loads(raw or b'{}'), res
        except json.JSONDecodeError:
            return res.status, raw.decode(), res

    def setup_account(self, user='family', password='correct-horse'):
        code = server.setup_code()
        status, body, _ = self.call('POST', '/v1/setup', None, {'code': code, 'username': user, 'password': password})
        self.assertEqual((status, body), (200, {'ok': True}))
        return basic(user, password)

    # ---- 首次设置 ----

    def test_setup_flow(self):
        self.assertEqual(self.call('GET', '/health')[1], {'ok': True, 'setup': True, 'configured': False})
        # 没设置账号前，需要登录的接口都提示先设置
        self.assertEqual(self.call('GET', '/v1/credential', basic('a', 'b'))[:2], (409, {'error': 'setup_required'}))
        self.assertEqual(self.call('GET', '/v1/status')[0], 409)
        code = server.setup_code()
        stat_mode = stat.S_IMODE(os.stat(os.path.join(self.state, 'setup_code')).st_mode)
        self.assertEqual(stat_mode, 0o600)
        good = {'code': code, 'username': 'family', 'password': 'correct-horse'}
        self.assertEqual(self.call('POST', '/v1/setup', None, {**good, 'code': 'wrong'})[:2], (403, {'error': 'wrong_setup_code'}))
        self.assertEqual(self.call('POST', '/v1/setup', None, {**good, 'username': 'a:b'})[1], {'error': 'invalid_username'})
        self.assertEqual(self.call('POST', '/v1/setup', None, {**good, 'username': ''})[1], {'error': 'invalid_username'})
        self.assertEqual(self.call('POST', '/v1/setup', None, {**good, 'password': 'short'})[1], {'error': 'invalid_password'})
        self.assertEqual(self.call('POST', '/v1/setup', None, good)[:2], (200, {'ok': True}))
        # 初始化口令用完即删，不能再次设置
        self.assertFalse(os.path.exists(os.path.join(self.state, 'setup_code')))
        self.assertEqual(self.call('POST', '/v1/setup', None, good)[:2], (409, {'error': 'already_set_up'}))
        self.assertEqual(self.call('GET', '/health')[1]['setup'], False)
        # 登录
        self.assertEqual(self.call('GET', '/v1/credential')[0], 401)
        self.assertEqual(self.call('GET', '/v1/credential', basic('family', 'wrong-pass'))[0], 401)
        self.assertEqual(self.call('GET', '/v1/credential', basic('other', 'correct-horse'))[0], 401)
        self.assertEqual(self.call('GET', '/v1/credential', 'Basic !!!')[0], 401)
        self.assertEqual(self.call('GET', '/v1/credential', basic('family', 'correct-horse'))[:2], (404, {'error': 'not_configured'}))
        mode = stat.S_IMODE(os.stat(os.path.join(self.state, 'account.json')).st_mode)
        self.assertEqual(mode, 0o600)
        # 密码不以明文保存
        self.assertNotIn('correct-horse', open(os.path.join(self.state, 'account.json')).read())

    def test_non_ascii_credentials(self):
        auth = self.setup_account('家人', '密码是中文也行啊')
        self.assertEqual(self.call('GET', '/v1/status', auth)[0], 200)

    # ---- 修改账号密码 ----

    def test_change_account(self):
        auth = self.setup_account()
        change = '/v1/account'
        self.assertEqual(self.call('POST', change, None, {'currentPassword': 'correct-horse'})[0], 401)
        self.assertEqual(self.call('POST', change, auth, {'currentPassword': 'nope', 'newPassword': 'brand-new-pass'})[1], {'error': 'wrong_password'})
        self.assertEqual(self.call('POST', change, auth, {'currentPassword': 'correct-horse', 'newPassword': 'short'})[1], {'error': 'invalid_password'})
        self.assertEqual(self.call('POST', change, auth, {'currentPassword': 'correct-horse', 'username': 'a:b'})[1], {'error': 'invalid_username'})
        # 只改用户名，密码不变
        self.assertEqual(self.call('POST', change, auth, {'currentPassword': 'correct-horse', 'username': 'friends'})[:2], (200, {'ok': True, 'username': 'friends'}))
        self.assertEqual(self.call('GET', '/v1/status', auth)[0], 401)
        self.assertEqual(self.call('GET', '/v1/status', basic('friends', 'correct-horse'))[1]['username'], 'friends')
        # 改密码，旧密码失效
        self.assertEqual(self.call('POST', change, basic('friends', 'correct-horse'),
                                   {'currentPassword': 'correct-horse', 'newPassword': 'brand-new-pass'})[0], 200)
        self.assertEqual(self.call('GET', '/v1/status', basic('friends', 'correct-horse'))[0], 401)
        self.assertEqual(self.call('GET', '/v1/status', basic('friends', 'brand-new-pass'))[0], 200)

    def test_reset_account_keeps_credential(self):
        auth = self.setup_account()
        self.call('POST', '/v1/credential/paste', auth, {'cookie': 'MUSIC_U=abc'})
        server.main(['server.py', 'reset-account'])
        self.assertEqual(self.call('GET', '/health')[1], {'ok': True, 'setup': True, 'configured': True})
        self.assertEqual(self.call('GET', '/v1/credential', auth)[0], 409)
        auth = self.setup_account('new', 'another-pass-1')
        self.assertEqual(self.call('GET', '/v1/credential', auth)[1]['cookie'], {'MUSIC_U': 'abc'})

    # ---- 取链账号 ----

    def test_paste_and_verify(self):
        auth = self.setup_account()
        paste = '/v1/credential/paste'
        self.assertEqual(self.call('POST', paste, auth, {'cookie': 'bad-value'})[1], {'error': 'cookie_invalid'})
        self.assertEqual(self.call('POST', paste, auth, {'cookie': 'foo=bar'})[1], {'error': 'invalid_cookie'})
        self.assertEqual(self.call('POST', paste, auth, {'cookie': 5})[0], 400)
        status, body, _ = self.call('POST', paste, auth, {'cookie': 'MUSIC_U=pastedvalue; other=1'})
        self.assertEqual((status, body['account'], body['validated']), (200, {'nickname': '主人', 'vipType': 11}, True))
        status, body, res = self.call('GET', '/v1/credential', auth)
        self.assertEqual(body['cookie'], {'MUSIC_U': 'pastedvalue'})
        self.assertEqual(res.getheader('Cache-Control'), 'no-store')
        self.assertEqual(self.call('POST', '/v1/verify', auth)[1],
                         {'ok': True, 'level': 'lossless', 'type': 'flac', 'br': 900000, 'trial': False})
        self.call('POST', paste, auth, {'cookie': 'trialvalue'})
        self.assertEqual(self.call('POST', '/v1/verify', auth)[1]['ok'], False)
        mode = stat.S_IMODE(os.stat(os.path.join(self.state, 'credential.json')).st_mode)
        self.assertEqual(mode, 0o600)

    def test_qr_login_flow_never_leaks_cookie(self):
        auth = self.setup_account()
        status, body, _ = self.call('POST', '/v1/qr/start', auth)
        self.assertEqual((status, body['key']), (200, 'fake-key'))
        self.assertTrue(body['qrimg'].startswith('data:image/png;base64,'))
        self.assertEqual(self.call('GET', '/v1/qr/check?key=fake-key', auth)[1], {'code': 801})
        status, body, _ = self.call('GET', '/v1/qr/check?key=fake-key', auth)
        self.assertEqual(status, 200)
        self.assertEqual(body['account'], {'nickname': '主人', 'vipType': 11})
        self.assertNotIn('scanned-secret', json.dumps(body))
        self.assertNotIn('scanned-secret', json.dumps(self.call('GET', '/v1/status', auth)[1]))
        got = self.call('GET', '/v1/credential', auth)[1]['cookie']
        self.assertEqual(got, {'MUSIC_U': 'scanned-secret', '__csrf': 'csrf1', 'NMTID': 'n1'})

    def test_without_netease_api(self):
        server.NETEASE_API = ''
        auth = self.setup_account()
        self.assertEqual(self.call('GET', '/v1/status', auth)[1]['netease'], False)
        self.assertEqual(self.call('POST', '/v1/qr/start', auth)[:2], (501, {'error': 'netease_api_not_configured'}))
        self.assertEqual(self.call('POST', '/v1/verify', auth)[0], 404)  # 还没有账号
        status, body, _ = self.call('POST', '/v1/credential/paste', auth, {'cookie': 'rawvalue'})
        self.assertEqual((status, body['validated'], body['account']['nickname']), (200, False, ''))
        self.assertEqual(self.call('POST', '/v1/verify', auth)[0], 501)

    def test_upstream_down_gives_502(self):
        auth = self.setup_account()
        server.NETEASE_API = 'http://127.0.0.1:1'
        self.assertEqual(self.call('POST', '/v1/qr/start', auth)[0], 502)

    # ---- 页面与限流 ----

    def test_admin_page(self):
        for path in ('/', '/admin'):
            status, html, res = self.call('GET', path)
            self.assertEqual(status, 200)
            self.assertIn('text/html', res.getheader('Content-Type'))
            self.assertIn("default-src 'none'", res.getheader('Content-Security-Policy'))
            self.assertEqual(res.getheader('X-Frame-Options'), 'DENY')
            self.assertIn('取链服务', html)

    def test_throttle(self):
        auth = self.setup_account()
        bad = basic('family', 'wrong-pass')
        for _ in range(server.FAIL_LIMIT):
            self.assertEqual(self.call('GET', '/v1/status', bad)[0], 401)
        self.assertEqual(self.call('GET', '/v1/status', bad)[0], 429)
        self.assertEqual(self.call('GET', '/v1/status', auth)[0], 429)

    def test_methods(self):
        auth = self.setup_account()
        self.assertEqual(self.call('PUT', '/v1/credential', auth, {})[0], 405)
        self.assertEqual(self.call('GET', '/nope')[0], 404)


if __name__ == '__main__':
    unittest.main()
