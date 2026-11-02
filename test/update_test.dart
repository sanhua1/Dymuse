import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dymuse/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('版本号比较', () {
    expect(compareVersions('0.2.1', '0.2.0'), greaterThan(0));
    expect(compareVersions('v0.10.0', '0.9.9'), greaterThan(0));
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('0.2.0+5', '0.2.0'), 0);
    expect(compareVersions('0.1.9', '0.2.0'), lessThan(0));
  });

  test('代码里的版本号与 pubspec.yaml 一致', () {
    final text = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*(\S+)\+(\d+)',
      multiLine: true,
    ).firstMatch(text)!;
    expect(match[1], appVersion);
    expect(int.parse(match[2]!), appBuild);
  });

  group('检测与下载', () {
    late HttpServer server;
    late SharedPreferences prefs;
    final package = utf8.encode('fake package bytes' * 100);
    final goodSha = sha256.convert(package).toString();
    var releaseBody = <String, Object?>{};
    var manifestBody = <String, Object?>{};
    var failApi = false;
    final served = <String>[];
    String base() => 'http://127.0.0.1:${server.port}';

    setUp(() async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      served.clear();
      failApi = false;
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        served.add(request.uri.path);
        final response = request.response;
        if (request.uri.path.endsWith('/latest')) {
          if (failApi) {
            response.statusCode = 500;
          } else {
            response.headers.contentType = ContentType.json;
            response.write(
              jsonEncode({
                ...releaseBody,
                'assets': [
                  {
                    'name': 'latest.json',
                    'browser_download_url': '${base()}/dl/v9.9.9/latest.json',
                  },
                ],
              }),
            );
          }
        } else if (request.uri.path.endsWith('latest.json')) {
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(manifestBody));
        } else if (request.uri.path.endsWith('pkg.zip')) {
          response.add(package);
        } else {
          response.statusCode = 404;
        }
        await response.close();
      });
      releaseBody = {'tag_name': 'v9.9.9', 'prerelease': false};
      manifestBody = {
        'version': '9.9.9',
        'notes': '新功能',
        'assets': {
          'windows-x64': {
            'name': 'pkg.zip',
            'size': package.length,
            'sha256': goodSha,
          },
        },
      };
    });
    tearDown(() => server.close(force: true));

    UpdateService service({
      List<UpdateSource>? sources,
      String platform = 'windows-x64',
    }) => UpdateService(
      prefs,
      sources:
          sources ??
          [UpdateSource('测试', '${base()}/api/latest', '${base()}/dl')],
      platform: platform,
    );

    test('有新版本：给出说明、安装包与下载地址', () async {
      final info = (await service().check())!;
      expect(info.version, '9.9.9');
      expect(info.notes, '新功能');
      expect(info.asset!.name, 'pkg.zip');
      expect(info.downloadUrls, ['${base()}/dl/v9.9.9/pkg.zip']);
    });

    test('已是最新、预发布、没有本平台安装包', () async {
      manifestBody['version'] = appVersion;
      expect(await service().check(), isNull);
      manifestBody['version'] = '9.9.9';
      releaseBody['prerelease'] = true;
      expect(await service().check(), isNull);
      releaseBody['prerelease'] = false;
      final ios = (await service(platform: 'ios').check())!;
      expect(ios.asset, isNull);
      expect(ios.downloadUrls, isEmpty);
    });

    test('第一个源不可用就回退到下一个；都不可用则报错', () async {
      final dead = UpdateSource(
        '坏',
        'http://127.0.0.1:1/api/latest',
        'http://127.0.0.1:1/dl',
      );
      final ok = UpdateSource('好', '${base()}/api/latest', '${base()}/dl');
      final info = (await service(sources: [dead, ok]).check())!;
      expect(info.sourceName, '好');
      await expectLater(
        service(sources: [dead]).check(),
        throwsA(isA<UpdateError>()),
      );
    });

    test('下载后校验 SHA-256：正确通过，不符则换下一个地址并最终失败', () async {
      final s = service();
      final info = (await s.check())!;
      final file = await s.download(info);
      expect(await file.readAsBytes(), package);

      manifestBody['assets'] = {
        'windows-x64': {
          'name': 'pkg.zip',
          'size': package.length,
          'sha256': 'a' * 64,
        },
      };
      final bad = (await s.check())!;
      await expectLater(s.download(bad), throwsA(isA<UpdateError>()));
    });

    test('忽略此版本会被记住；下载源优先级可切换', () async {
      final s = service(
        sources: [
          const UpdateSource('一', 'http://a/api/latest', 'http://a/dl'),
          const UpdateSource('二', 'http://b/api/latest', 'http://b/dl'),
        ],
      );
      expect(s.ignoredVersion, isNull);
      await s.ignore('9.9.9');
      expect(service().ignoredVersion, '9.9.9');
      expect(s.githubFirst, isFalse);
      await s.setGithubFirst(true);
      expect(s.githubFirst, isTrue);
    });
  });

  test('Release 网页地址按 tag 拼出', () {
    expect(
      giteeSource.pageUrl('v0.2.1'),
      'https://gitee.com/sanhua1/dymuserelease/releases/tag/v0.2.1',
    );
    expect(
      githubSource.pageUrl('v0.2.1'),
      'https://github.com/sanhua1/Dymuse/releases/tag/v0.2.1',
    );
  });
}
