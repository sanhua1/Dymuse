import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import 'catalog.dart';
import '../design_system/components.dart';

/// B 站订阅的添加、编辑、刷新与删除。所有改动只写本机，不碰 B 站账号数据。
class SubscriptionActions {
  const SubscriptionActions(this.api);
  final ApiClient api;

  /// 表单从底部弹出，宽度随屏幕，键盘出现时整体上移。
  static Future<bool?> _form(BuildContext context, Widget form) =>
      showFormSheet<bool>(context, form);

  /// 添加订阅；成功返回 true。
  /// [input]、[name] 用来预填（例如从搜索结果跳转到来源后一键订阅）。
  Future<bool> add(BuildContext context, {String? input, String? name}) async =>
      await _form(
        context,
        _SubscriptionDialog(api: api, initialInput: input, initialName: name),
      ) ??
      false;

  /// 编辑订阅（改名称，或换成新的来源）；成功返回 true。
  Future<bool> edit(BuildContext context, Collection item) async {
    final Json current;
    try {
      current = await api.get('/bilibili/subscriptions/${item.id}') as Json;
    } catch (error) {
      if (context.mounted) await _notice(context, '无法编辑', readableError(error));
      return false;
    }
    if (!context.mounted) return false;
    return await _form(
          context,
          _SubscriptionDialog(api: api, current: current),
        ) ??
        false;
  }

  /// 从 B 站重新取回内容并替换本地保存的歌曲。
  Future<bool> refresh(BuildContext context, Collection item) async {
    try {
      await api.post('/bilibili/subscriptions/${item.id}/refresh', {});
      return true;
    } catch (error) {
      if (context.mounted) await _notice(context, '刷新失败', readableError(error));
      return false;
    }
  }

  /// 删除订阅需要二次确认；只删除本机保存的订阅。
  Future<bool> delete(BuildContext context, Collection item) async {
    final sure = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text('删除“${item.title}”？'),
        content: const Text('只会删除本机上的订阅记录，不影响 B 站上的内容。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (sure != true) return false;
    try {
      await api.post('/bilibili/subscriptions/${item.id}/delete', {});
      return true;
    } catch (error) {
      if (context.mounted) await _notice(context, '删除失败', readableError(error));
      return false;
    }
  }

  static Future<void> _notice(
    BuildContext context,
    String title,
    String message,
  ) => showCupertinoDialog<void>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('好'),
        ),
      ],
    ),
  );
}

class _SubscriptionDialog extends StatefulWidget {
  const _SubscriptionDialog({
    required this.api,
    this.current,
    this.initialInput,
    this.initialName,
  });
  final ApiClient api;
  final String? initialInput, initialName;
  final Json? current;
  @override
  State<_SubscriptionDialog> createState() => _SubscriptionDialogState();
}

class _SubscriptionDialogState extends State<_SubscriptionDialog> {
  late final source = TextEditingController(
    text: widget.current?['source']?.toString() ?? widget.initialInput ?? '',
  );
  late final name = TextEditingController(
    text: widget.current?['name']?.toString() ?? widget.initialName ?? '',
  );
  bool busy = false;
  String? error;

  bool get editing => widget.current != null;

  @override
  void dispose() {
    source.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (source.text.trim().isEmpty) {
      setState(() => error = '请粘贴订阅的链接或编号。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      // 名称没改过就不当作自定义名称，之后刷新仍跟随 B 站改名。
      final typed = name.text.trim();
      final body = {
        'input': source.text.trim(),
        'name': typed == widget.initialName ? '' : typed,
      };
      if (editing) {
        await widget.api.put(
          '/bilibili/subscriptions/${widget.current!['id']}',
          body,
        );
      } else {
        await widget.api.post('/bilibili/subscriptions', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = readableError(failure);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);
    Widget field(
      TextEditingController c,
      String label,
      String hint, {
      int lines = 1,
      VoidCallback? submit,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: secondary)),
        const SizedBox(height: 6),
        CupertinoTextField(
          controller: c,
          placeholder: hint,
          enabled: !busy,
          minLines: lines,
          maxLines: lines + 2,
          padding: const EdgeInsets.all(12),
          style: const TextStyle(fontSize: 16),
          placeholderStyle: TextStyle(fontSize: 15, color: secondary),
          onSubmitted: submit == null ? null : (_) => submit(),
        ),
      ],
    );
    return CupertinoPopupSurface(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  Expanded(
                    child: Text(
                      editing ? '编辑订阅' : '添加订阅',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy ? null : submit,
                    child: Text(
                      editing ? '保存' : '添加',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              field(source, '来源', '粘贴合集、系列、收藏夹、UP 主主页或视频链接', lines: 2),
              const SizedBox(height: 16),
              field(name, '名称（可选）', '留空则使用 B 站上的名称', submit: submit),
              if (busy) ...[
                const SizedBox(height: 18),
                const Center(child: CupertinoActivityIndicator()),
                const SizedBox(height: 6),
                Text(
                  '正在读取内容，内容较多时需要一会儿…',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: secondary),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 14),
                Text(
                  error!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemRed,
                  ),
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
