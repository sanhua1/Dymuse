import 'package:dymuse/update/mac_installer.dart';
import 'package:flutter_test/flutter_test.dart';

// 真正的安装流程会用 open 弹出安装盘窗口，测试里不跑；这里只核对给用户看的说明与命令。
void main() {
  test('macOS 更新说明：包含替换步骤、被拦下时的放行方法', () {
    expect(macInstallSteps, contains('选择“替换”'));
    expect(macInstallSteps, contains('隐私与安全性'));
    expect(macInstallSteps, contains('仍要打开'));
    expect(macInstallSteps, contains('复制命令'));
  });

  test('放行命令只去掉 Dymuse 的隔离标记', () {
    expect(
      macQuarantineFix,
      'xattr -dr com.apple.quarantine /Applications/Dymuse.app',
    );
  });
}
