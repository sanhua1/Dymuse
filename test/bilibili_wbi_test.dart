import 'package:dymuse/bilibili/wbi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 参数与两个 key 取自 bilibili-API-collect 的 WBI 文档示例；w_rid 用独立的 md5 计算核对。
  const imgKey = '7cd084941338484aae1ad9425b84077c';
  const subKey = '4932caff0ff746eab6f01bf08b70ac45';

  test('混淆后的 mixin key', () {
    expect(mixinKey(imgKey, subKey), 'ea1db124af3c7062474693fa704f4ff8');
  });

  test('签名查询串按 key 排序并带 w_rid', () {
    final query = signWbi(
      {'foo': '114', 'bar': '514', 'zab': 1919810},
      imgKey: imgKey,
      subKey: subKey,
      timestamp: 1684746385,
    );
    expect(
      query,
      'bar=514&foo=114&wts=1684746385&zab=1919810'
      '&w_rid=72c16126b5c96f58937ead1e1ee9dad0',
    );
  });

  test('值里的特殊字符被过滤', () {
    final query = signWbi(
      {'q': "a!b'c(d)e*f"},
      imgKey: imgKey,
      subKey: subKey,
      timestamp: 1,
    );
    expect(query.startsWith('q=abcdef&wts=1&w_rid='), isTrue);
  });
}
