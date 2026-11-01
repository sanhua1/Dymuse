#!/usr/bin/env python3
"""Dymuse 取链服务。

多人共享同一个网易云会员账号取链：服务保存一份取链账号的 Cookie，
App 用「服务地址 + 账号 + 密码」登录后拉取它，只用于取歌曲链接。

- 首次访问 /admin 时设置账号和密码（需要启动日志里的初始化口令），之后可以在面板里修改。
- 面板里可以扫码登录、粘贴 Cookie、验证取链；扫码、验证借用 api-enhanced 网易云 API
  （环境变量 DYMUSE_NETEASE_API，未配置时只能粘贴 Cookie，保存时不核对账号）。
- Cookie 只保存在服务端，不会发给浏览器；App 拿到的也只是取链需要的三项。
只依赖 Python 标准库。用法：

    server.py serve          启动服务
    server.py setup-code     打印初始化口令（还没有设置账号时）
    server.py reset-account  忘记密码时：清除账号密码，重新走首次设置（取链账号保留）
    server.py status         看账号和取链账号状态
"""
import base64
import binascii
import hashlib
import hmac
import json
import os
import secrets
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ.get('DYMUSE_STATE', '/data')
BIND = os.environ.get('DYMUSE_BIND', '127.0.0.1')
PORT = int(os.environ.get('DYMUSE_PORT', '8080'))
NETEASE_API = os.environ.get('DYMUSE_NETEASE_API', '').rstrip('/')
ADMIN_PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'admin.html')
# 验证取链用的歌曲（陈奕迅《十年》，需要会员才有无损）。
VERIFY_SONG = '66842'
MAX_BODY = 16 * 1024
# 只保存取链需要的 Cookie 项，其余一律丢弃。
COOKIE_KEYS = ('MUSIC_U', '__csrf', 'NMTID')
FAIL_LIMIT, FAIL_WINDOW = 20, 600
SCRYPT = {'n': 2 ** 14, 'r': 8, 'p': 1, 'dklen': 32, 'maxmem': 64 * 1024 * 1024}
MIN_PASSWORD, MAX_PASSWORD, MAX_USERNAME = 8, 128, 32


def _path(name):
    return os.path.join(STATE, name)


def _write_private(name, data):
    """原子写入，文件权限 0600。"""
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix='.tmp-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, _path(name))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _read(name):
    try:
        with open(_path(name), encoding='utf-8') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


# ---- 账号密码 ----

def _hash(password, salt):
    return hashlib.scrypt(password.encode(), salt=salt, **SCRYPT)


def valid_username(username):
    return (isinstance(username, str) and 1 <= len(username) <= MAX_USERNAME
            and ':' not in username and username == username.strip() and username.isprintable())


def valid_password(password):
    return isinstance(password, str) and MIN_PASSWORD <= len(password) <= MAX_PASSWORD


def save_account(username, password):
    salt = secrets.token_bytes(16)
    _write_private('account.json', {
        'username': username,
        'salt': salt.hex(),
        'hash': _hash(password, salt).hex(),
        'updatedAt': datetime.now(timezone.utc).isoformat(timespec='seconds'),
    })


def check_login(username, password):
    """账号还没设置时返回 None，否则返回用户名密码是否正确。"""
    account = _read('account.json')
    if not account:
        return None
    try:
        expected = bytes.fromhex(account['hash'])
        salt = bytes.fromhex(account['salt'])
    except (KeyError, ValueError):
        return False
    # 不论用户名对不对都算一次哈希，避免靠耗时猜用户名。
    good = hmac.compare_digest(_hash(password, salt), expected)
    return hmac.compare_digest(username.encode(), str(account.get('username', '')).encode()) and good


def setup_code(create=True):
    """初始化口令：没有账号时存在，设置完成后删除。"""
    try:
        with open(_path('setup_code'), encoding='utf-8') as f:
            return f.read().strip()
    except FileNotFoundError:
        if not create:
            return None
    code = secrets.token_hex(6)
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    fd = os.open(_path('setup_code'), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(code)
    return code


def _forget_setup_code():
    try:
        os.unlink(_path('setup_code'))
    except FileNotFoundError:
        pass


# ---- 网易云（可选） ----

class UpstreamError(Exception):
    pass


class NotConfigured(Exception):
    pass


def netease(path, params=None, form=None):
    """调用网易云 API 服务；失败统一抛 UpstreamError。"""
    if not NETEASE_API:
        raise NotConfigured()
    url = NETEASE_API + path + ('?' + urllib.parse.urlencode(params) if params else '')
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    request = urllib.request.Request(url, data=data, headers={'User-Agent': 'DymuseLinkService/1.0'})
    try:
        with urllib.request.urlopen(request, timeout=15) as res:
            return json.load(res)
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise UpstreamError(str(error)) from error


def parse_cookie(text):
    """从 Set-Cookie 拼接串、Cookie 头或单独的 MUSIC_U 值里取出需要的项。"""
    text = (text or '').strip()
    if text and '=' not in text:
        text = 'MUSIC_U=' + text
    found = {}
    for part in text.split(';'):
        key, _, value = part.strip().partition('=')
        value = value.strip()
        if key in COOKIE_KEYS and value:
            found[key] = value
    return found


def cookie_header(cookie):
    return '; '.join(f'{key}={value}' for key, value in cookie.items())


def describe(cookie):
    """向网易云查这份 Cookie 属于谁；无效返回 None，否则 (昵称, 会员类型)。"""
    body = netease('/user/account', form={'cookie': cookie_header(cookie), 'timestamp': str(int(time.time() * 1000))})
    profile = body.get('profile') if isinstance(body, dict) else None
    if not isinstance(profile, dict) or not profile.get('nickname'):
        return None
    account = body.get('account') if isinstance(body.get('account'), dict) else {}
    vip = account.get('vipType', profile.get('vipType', 0))
    return str(profile['nickname']), vip if isinstance(vip, int) else 0


def store_credential(cookie, nickname='', vip=0):
    saved = {key: value for key, value in cookie.items() if key in COOKIE_KEYS and 0 < len(value) <= 4096}
    previous = _read('credential.json') or {}
    record = {
        'cookie': saved,
        'account': {
            'nickname': nickname[:64],
            'vipType': vip if isinstance(vip, int) and 0 <= vip <= 99 else 0,
        },
        'version': int(previous.get('version', 0)) + 1,
        'updatedAt': datetime.now(timezone.utc).isoformat(timespec='seconds'),
    }
    _write_private('credential.json', record)
    return record


# ---- 失败限流 ----

_fails = {}
_fails_lock = threading.Lock()


def _blocked(ip):
    now = time.time()
    with _fails_lock:
        recent = [t for t in _fails.get(ip, []) if now - t < FAIL_WINDOW]
        _fails[ip] = recent
        return len(recent) >= FAIL_LIMIT


def _fail(ip):
    with _fails_lock:
        _fails.setdefault(ip, []).append(time.time())


class Handler(BaseHTTPRequestHandler):
    server_version = 'DymuseLinkService'
    sys_version = ''
    timeout = 10

    def log_message(self, *args):  # 默认日志含请求行，统一改成不含任何凭据的一行
        pass

    def _ip(self):
        return self.headers.get('CF-Connecting-IP') or self.headers.get('X-Real-IP') or self.client_address[0]

    def _send(self, status, body, raw=None, content_type='application/json; charset=utf-8'):
        data = raw if raw is not None else json.dumps(body, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        if raw is not None:
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header(
                'Content-Security-Policy',
                "default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
                "script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'",
            )
        self.end_headers()
        self.wfile.write(data)
        sys.stderr.write(f'{self._ip()} {self.command} {self.path.split("?")[0]} {status}\n')

    def _body(self):
        """先把（有上限的）请求体读完再处理：提前回复会让客户端看到连接被重置。"""
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = -1
        if not 0 <= length <= MAX_BODY:
            self.close_connection = True
            return None
        return self.rfile.read(length) if length else b''

    def _json(self, raw):
        try:
            body = json.loads(raw or b'{}')
        except json.JSONDecodeError:
            return None
        return body if isinstance(body, dict) else None

    def _credentials(self):
        header = self.headers.get('Authorization', '')
        if not header.startswith('Basic '):
            return None
        try:
            text = base64.b64decode(header[6:].strip(), validate=True).decode('utf-8')
        except (binascii.Error, UnicodeDecodeError):
            return None
        user, sep, password = text.partition(':')
        return (user, password) if sep else None

    def _auth(self):
        """鉴权；失败时已回复并返回 False。"""
        ip = self._ip()
        if _blocked(ip):
            self._send(429, {'error': 'too_many_attempts'})
            return False
        given = self._credentials()
        ok = check_login(*given) if given else (None if _read('account.json') is None else False)
        if ok is None:
            self._send(409, {'error': 'setup_required'})
            return False
        if not ok:
            _fail(ip)
            self._send(401, {'error': 'unauthorized'})
            return False
        return True

    def _guard(self, action):
        try:
            action()
        except UpstreamError:
            self._send(502, {'error': 'upstream_failed'})
        except NotConfigured:
            self._send(501, {'error': 'netease_api_not_configured'})

    def do_GET(self):
        path, _, query = self.path.partition('?')
        if path in ('/', '/admin'):
            try:
                with open(ADMIN_PAGE, 'rb') as f:
                    return self._send(200, None, raw=f.read(), content_type='text/html; charset=utf-8')
            except OSError:
                return self._send(404, {'error': 'not_found'})
        if path == '/health':
            return self._send(200, {
                'ok': True,
                'setup': _read('account.json') is None,
                'configured': _read('credential.json') is not None,
            })
        if path == '/v1/credential':
            if not self._auth():
                return
            saved = _read('credential.json')
            if not saved:
                return self._send(404, {'error': 'not_configured'})
            return self._send(200, saved)
        if path == '/v1/status':
            if not self._auth():
                return
            return self._send(200, self._status())
        if path == '/v1/qr/check':
            if not self._auth():
                return
            key = urllib.parse.parse_qs(query).get('key', [''])[0]
            return self._guard(lambda: self._qr_check(key))
        self._send(404, {'error': 'not_found'})

    def do_POST(self):
        path = self.path.split('?')[0]
        raw = self._body()
        if path not in ('/v1/setup', '/v1/account', '/v1/qr/start', '/v1/credential/paste', '/v1/verify'):
            return self._send(404, {'error': 'not_found'})
        if raw is None:
            return self._send(400, {'error': 'invalid_body'})
        if path == '/v1/setup':
            return self._setup(raw)
        if not self._auth():
            return
        if path == '/v1/verify':
            return self._guard(self._verify)
        if path == '/v1/qr/start':
            return self._guard(self._qr_start)
        body = self._json(raw)
        if body is None:
            return self._send(400, {'error': 'invalid_body'})
        if path == '/v1/account':
            return self._change_account(body)
        text = body.get('cookie', '')
        self._guard(lambda: self._save_cookie(parse_cookie(text if isinstance(text, str) else ''), {}))

    def do_PUT(self):
        self._send(405, {'error': 'method_not_allowed'})

    do_DELETE = do_PUT

    # ---- 首次设置与账号修改 ----

    def _setup(self, raw):
        ip = self._ip()
        if _blocked(ip):
            return self._send(429, {'error': 'too_many_attempts'})
        if _read('account.json') is not None:
            return self._send(409, {'error': 'already_set_up'})
        body = self._json(raw)
        if body is None:
            return self._send(400, {'error': 'invalid_body'})
        expected = setup_code()
        given = body.get('code')
        if not isinstance(given, str) or not hmac.compare_digest(given.strip().encode(), expected.encode()):
            _fail(ip)
            return self._send(403, {'error': 'wrong_setup_code'})
        username, password = body.get('username'), body.get('password')
        if not valid_username(username):
            return self._send(400, {'error': 'invalid_username'})
        if not valid_password(password):
            return self._send(400, {'error': 'invalid_password'})
        save_account(username, password)
        _forget_setup_code()
        self._send(200, {'ok': True})

    def _change_account(self, body):
        """改用户名和/或密码；必须再输一次当前密码。"""
        account = _read('account.json') or {}
        current = body.get('currentPassword')
        if not isinstance(current, str) or not check_login(account.get('username', ''), current):
            _fail(self._ip())
            return self._send(403, {'error': 'wrong_password'})
        username = body.get('username', account.get('username'))
        password = body.get('newPassword') or current
        if not valid_username(username):
            return self._send(400, {'error': 'invalid_username'})
        if not valid_password(password):
            return self._send(400, {'error': 'invalid_password'})
        save_account(username, password)
        self._send(200, {'ok': True, 'username': username})

    # ---- 取链账号 ----

    def _status(self):
        saved = _read('credential.json')
        return {
            'username': (_read('account.json') or {}).get('username', ''),
            'netease': bool(NETEASE_API),
            'configured': saved is not None,
            'account': (saved or {}).get('account', {}),
            'version': (saved or {}).get('version'),
            'updatedAt': (saved or {}).get('updatedAt'),
        }

    def _qr_start(self):
        stamp = str(int(time.time() * 1000))
        key = (netease('/login/qr/key', params={'timestamp': stamp}).get('data') or {}).get('unikey')
        if not isinstance(key, str) or not key:
            raise UpstreamError('no key')
        image = (netease('/login/qr/create', params={'key': key, 'qrimg': 'true', 'timestamp': stamp})
                 .get('data') or {}).get('qrimg')
        if not isinstance(image, str) or not image.startswith('data:image/png;base64,'):
            raise UpstreamError('no image')
        self._send(200, {'key': key, 'qrimg': image})

    def _qr_check(self, key):
        if not key or len(key) > 64:
            return self._send(400, {'error': 'invalid_key'})
        body = netease('/login/qr/check', params={'key': key, 'timestamp': str(int(time.time() * 1000))})
        code = body.get('code') if isinstance(body, dict) else None
        if code != 803:
            return self._send(200, {'code': code if code in (800, 801, 802) else 0})
        self._save_cookie(parse_cookie(body.get('cookie', '')), {'code': 803})

    def _save_cookie(self, cookie, extra):
        if 'MUSIC_U' not in cookie:
            return self._send(400, {'error': 'invalid_cookie'})
        if NETEASE_API:
            who = describe(cookie)
            if who is None:
                return self._send(400, {'error': 'cookie_invalid'})
        else:
            who = ('', 0)  # 没有网易云 API 时无法核对，原样保存
        saved = store_credential(cookie, *who)
        self._send(200, {**extra, 'ok': True, 'account': saved['account'], 'version': saved['version'],
                         'updatedAt': saved['updatedAt'], 'validated': bool(NETEASE_API)})

    def _verify(self):
        saved = _read('credential.json')
        if not saved:
            return self._send(404, {'error': 'not_configured'})
        body = netease('/song/url/v1', form={
            'id': VERIFY_SONG,
            'level': 'lossless',
            'cookie': cookie_header(saved['cookie']),
            'timestamp': str(int(time.time() * 1000)),
        })
        item = (body.get('data') or [{}])[0] if isinstance(body, dict) else {}
        trial = bool(item.get('freeTrialInfo'))
        self._send(200, {
            'ok': bool(item.get('url')) and not trial,
            'level': item.get('level'),
            'type': item.get('type'),
            'br': item.get('br'),
            'trial': trial,
        })


def serve():
    if _read('account.json') is None:
        sys.stderr.write(
            f'首次使用：打开 /admin 设置账号和密码，初始化口令：{setup_code()}\n'
            '（之后也可以运行 server.py setup-code 查看）\n')
    sys.stderr.flush()
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()


def main(argv):
    command = argv[1] if len(argv) > 1 else ''
    if command == 'serve':
        serve()
    elif command == 'setup-code':
        if _read('account.json') is not None:
            print('已经设置过账号；忘记密码请运行 reset-account。')
        else:
            print(setup_code())
    elif command == 'reset-account':
        try:
            os.unlink(_path('account.json'))
        except FileNotFoundError:
            pass
        print('账号密码已清除，取链账号保留。重新打开 /admin 设置，初始化口令：', setup_code(), sep='')
    elif command == 'status':
        account = _read('account.json')
        print('登录账号：' + (account['username'] if account else '尚未设置（等待首次设置）'))
        saved = _read('credential.json')
        if not saved:
            print('取链账号：未配置')
        else:
            info = saved.get('account', {})
            print(f"取链账号：{info.get('nickname') or '(未核对昵称)'}，vipType={info.get('vipType')}，"
                  f"版本 {saved.get('version')}，更新于 {saved.get('updatedAt')}")
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
