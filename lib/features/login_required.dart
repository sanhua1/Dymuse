import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';

/// 游客进入依赖网易云账号的页面时显示的提示，带跳转登录的入口。
class LoginRequiredView extends StatelessWidget {
  const LoginRequiredView({super.key, required this.api, this.title});
  final ApiClient api;

  /// 页面名，例如“我喜欢”；为空时用通用标题。
  final String? title;
  @override
  Widget build(BuildContext context) => StatusMessage(
    title: title == null ? '需要登录网易云账号' : '$title需要登录网易云账号',
    message: '请登录网易云账号之后使用这些功能。游客可以搜索、浏览和播放音乐。',
    icon: CupertinoIcons.person_crop_circle,
    action: ActionButton(
      label: '登录网易云账号',
      filled: true,
      onPressed: api.requestLogin,
    ),
  );
}

/// 需要网易云账号的操作（红心、加入歌单、收藏歌单）：已登录返回 true；
/// 游客则弹出提示并提供“去登录”，返回 false。
Future<bool> ensureLoggedIn(BuildContext context, ApiClient api) async {
  if (!api.guest) return true;
  final go = await showCupertinoDialog<bool>(
    context: context,
    builder: (dialog) => CupertinoAlertDialog(
      title: const Text('需要登录网易云账号'),
      content: const Text('请登录网易云账号之后使用这些功能。'),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('取消'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.pop(dialog, true),
          child: const Text('去登录'),
        ),
      ],
    ),
  );
  if (go == true) api.requestLogin();
  return false;
}
