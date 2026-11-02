#!/usr/bin/env python3
"""生成 latest.json，并把安装包发布到 GitHub Release 与 Gitee Release。

只在 Mac 上执行（发布不在 Windows 机器上做）。只用标准库；GitHub 用 gh 命令行。
用法示例（在发布仓库根目录）：
  python3 tool/release.py --version 0.2.1 --build 3 --notes notes.md \
      --windows ~/release/Dymuse-windows-x64.zip \
      --android build/app/outputs/flutter-apk/app-release.apk
默认只做“演练”：生成清单并打印将要上传的内容；加 --publish 才真正发布。
Gitee 令牌从环境变量 GITEE_TOKEN 或 --gitee-token-file 读取，不会被打印。
"""
import argparse
import hashlib
import json
import mimetypes
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

GITEE_API = 'https://gitee.com/api/v5'
GITEE_REPO = 'sanhua1/dymuserelease'
GITHUB_REPO = 'sanhua1/Dymuse'

# 清单里的平台键与客户端 UpdateService.platformKey 一致；文件名固定，下载地址才能由 tag 拼出。
PLATFORMS = {
    'windows': ('windows-x64', 'Dymuse-windows-x64.zip'),
    'android': ('android-arm64', 'Dymuse-android-arm64.apk'),
    'macos': ('macos', 'Dymuse-macos.zip'),
}


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def gitee(token, method, path, fields=None, file=None):
    """调用 Gitee v5 接口；file 为 (字段名, 本地路径, 上传文件名) 时走 multipart。"""
    url = f'{GITEE_API}{path}'
    fields = dict(fields or {}, access_token=token)
    if file is None:
        body = urllib.parse.urlencode(fields).encode()
        headers = {'Content-Type': 'application/x-www-form-urlencoded'}
    else:
        boundary = uuid.uuid4().hex
        parts = []
        for key, value in fields.items():
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"'
                f'\r\n\r\n{value}\r\n'.encode()
            )
        name, local, upload_name = file
        mime = mimetypes.guess_type(upload_name)[0] or 'application/octet-stream'
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
            f'filename="{upload_name}"\r\nContent-Type: {mime}\r\n\r\n'.encode()
        )
        with open(local, 'rb') as handle:
            parts.append(handle.read())
        parts.append(f'\r\n--{boundary}--\r\n'.encode())
        body = b''.join(parts)
        headers = {'Content-Type': f'multipart/form-data; boundary={boundary}'}
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            text = response.read().decode()
    except urllib.error.HTTPError as error:
        raise SystemExit(f'Gitee {method} {path} 失败：HTTP {error.code} {error.read().decode()[:300]}')
    return json.loads(text) if text else {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', required=True, type=int)
    parser.add_argument('--notes', required=True, help='更新说明（Markdown/纯文本文件）')
    for key in PLATFORMS:
        parser.add_argument(f'--{key}', help=f'{key} 安装包路径')
    parser.add_argument('--out', default='release-out', help='生成清单与改名后安装包的目录')
    parser.add_argument('--gitee-token-file')
    parser.add_argument('--publish', action='store_true', help='真正发布（默认只演练）')
    parser.add_argument('--skip-github', action='store_true')
    parser.add_argument('--skip-gitee', action='store_true')
    args = parser.parse_args()

    tag = f'v{args.version}'
    with open(args.notes, encoding='utf-8') as handle:
        notes = handle.read().strip()
    os.makedirs(args.out, exist_ok=True)

    assets, files = {}, []
    for key, (platform, name) in PLATFORMS.items():
        source = getattr(args, key)
        if not source:
            continue
        target = os.path.join(args.out, name)
        if os.path.abspath(source) != os.path.abspath(target):
            shutil.copyfile(source, target)
        assets[platform] = {
            'name': name,
            'size': os.path.getsize(target),
            'sha256': sha256_of(target),
        }
        files.append(target)
    if not assets:
        raise SystemExit('至少需要一个平台的安装包。')

    manifest = os.path.join(args.out, 'latest.json')
    with open(manifest, 'w', encoding='utf-8') as handle:
        json.dump(
            {'version': args.version, 'build': args.build, 'notes': notes, 'assets': assets},
            handle, ensure_ascii=False, indent=2,
        )
        handle.write('\n')
    print(f'清单：{manifest}')
    for platform, asset in assets.items():
        print(f'  {platform}: {asset["name"]} {asset["size"]} 字节 sha256={asset["sha256"]}')
    if not args.publish:
        print('演练结束，未发布。加 --publish 才会上传。')
        return

    # latest.json 最后上传：客户端读到清单时，安装包一定已经就位。
    upload_order = files + [manifest]

    if not args.skip_github:
        if not shutil.which('gh'):
            raise SystemExit('找不到 gh；可加 --skip-github 先发 Gitee。')
        subprocess.run(
            ['gh', 'release', 'create', tag, '--repo', GITHUB_REPO, '--draft',
             '--title', f'Dymuse {args.version}', '--notes-file', args.notes, *upload_order],
            check=True,
        )
        subprocess.run(
            ['gh', 'release', 'edit', tag, '--repo', GITHUB_REPO, '--draft=false', '--latest'],
            check=True,
        )
        print('GitHub Release 已发布。')

    if not args.skip_gitee:
        token = os.environ.get('GITEE_TOKEN', '')
        if not token and args.gitee_token_file:
            with open(args.gitee_token_file, encoding='utf-8') as handle:
                token = handle.read().strip()
        if not token:
            raise SystemExit('缺少 Gitee 令牌（GITEE_TOKEN 或 --gitee-token-file）。')
        release = gitee(token, 'POST', f'/repos/{GITEE_REPO}/releases', {
            'tag_name': tag, 'name': f'Dymuse {args.version}', 'body': notes,
            'prerelease': 'false', 'target_commitish': 'master',
        })
        for path in upload_order:
            gitee(token, 'POST', f'/repos/{GITEE_REPO}/releases/{release["id"]}/attach_files',
                  file=('file', path, os.path.basename(path)))
            print(f'Gitee 已上传 {os.path.basename(path)}')
        print('Gitee Release 已发布。')


if __name__ == '__main__':
    sys.exit(main())
