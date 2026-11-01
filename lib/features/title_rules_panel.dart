import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bilibili/title_rules.dart';
import '../core/session.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';

/// 设置页里的 B 站歌名识别：总开关、自定义规则、试一试。规则只存本机偏好并随同步传递。
class TitleRulesPanel extends StatefulWidget {
  const TitleRulesPanel({super.key, required this.session});
  final Session session;
  @override
  State<TitleRulesPanel> createState() => _TitleRulesPanelState();
}

class _TitleRulesPanelState extends State<TitleRulesPanel> {
  final title = TextEditingController(), uploader = TextEditingController();
  String? tried;

  @override
  void dispose() {
    title.dispose();
    uploader.dispose();
    super.dispose();
  }

  SharedPreferences prefs() => widget.session.preferences;
  bool get enabled => TitleRules.enabled(prefs());
  List<TitleRule> get custom => TitleRules.custom(prefs());

  Future<void> setEnabled(bool value) async {
    await prefs().setString(TitleRules.enabledKey, value ? '1' : '0');
    widget.session.titleRulesChanged();
    if (mounted) setState(() => tried = null);
  }

  bool get searchOn => TitleRules.searchEnabled(prefs());

  Future<void> setSearch(bool value) async {
    await prefs().setString(TitleRules.searchKey, value ? '1' : '0');
    widget.session.titleRulesChanged();
    if (mounted) setState(() {});
  }

  Future<void> save(List<TitleRule> rules) async {
    await TitleRules.saveCustom(prefs(), rules);
    widget.session.titleRulesChanged();
    if (mounted) setState(() => tried = null);
  }

  Future<void> edit(int? index) async {
    final rules = custom;
    final result = await showFormSheet<_Edit>(
      context,
      _RuleForm(current: index == null ? null : rules[index]),
    );
    if (result == null) return;
    if (result.rule == null) {
      if (index != null) await save([...rules]..removeAt(index));
    } else if (index == null) {
      await save([...rules, result.rule!]);
    } else {
      await save([...rules]..[index] = result.rule!);
    }
  }

  void tryIt() {
    final parser = TitleRules(custom: custom);
    setState(
      () => tried = title.text.trim().isEmpty
          ? null
          : parser.parse(title.text.trim(), uploader.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final secondary = DymuseTokens.secondary(context);
    final caption = DymuseTokens.caption.copyWith(
      color: secondary,
      height: 1.6,
    );
    final rules = custom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('订阅内正则开关', style: DymuseTokens.body)),
            CupertinoSwitch(value: enabled, onChanged: setEnabled),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(child: Text('搜索结果正则开关', style: DymuseTokens.body)),
            CupertinoSwitch(value: searchOn, onChanged: setSearch),
          ],
        ),
        ...[
          const SizedBox(height: 16),
          const Text(
            '自定义规则',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < rules.length; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => edit(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            rules[i].uploaders.isEmpty
                                ? '所有 UP 主'
                                : 'UP 主 ${rules[i].uploaders.join('、')}',
                            style: DymuseTokens.body,
                          ),
                          Text(
                            rules[i].patterns.isEmpty
                                ? '（没有正则）'
                                : rules[i].patterns.join('   '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: caption,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      CupertinoIcons.chevron_right,
                      size: 14,
                      color: secondary,
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          PanelButton(label: '添加规则', onPressed: () => edit(null)),
          const SizedBox(height: 20),
          const Text(
            '试一试',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          CupertinoTextField(
            controller: title,
            placeholder: '粘贴一个视频标题',
            onChanged: (_) => tryIt(),
          ),
          const SizedBox(height: 8),
          CupertinoTextField(
            controller: uploader,
            placeholder: 'UP 主 ID（可选）',
            keyboardType: TextInputType.number,
            onChanged: (_) => tryIt(),
          ),
          if (tried != null) ...[
            const SizedBox(height: 10),
            Text('识别结果：$tried', style: DymuseTokens.body),
          ],
        ],
      ],
    );
  }
}

class _Edit {
  const _Edit(this.rule);

  /// 为空表示删除。
  final TitleRule? rule;
}

class _RuleForm extends StatefulWidget {
  const _RuleForm({this.current});
  final TitleRule? current;
  @override
  State<_RuleForm> createState() => _RuleFormState();
}

class _RuleFormState extends State<_RuleForm> {
  late final ups = TextEditingController(
    text: widget.current?.uploaders.join(', ') ?? '',
  );
  late final patterns = TextEditingController(
    text: widget.current?.patterns.join('\n') ?? '',
  );
  late bool strip = widget.current?.stripsParenthesis ?? false;
  String? error;

  @override
  void dispose() {
    ups.dispose();
    patterns.dispose();
    super.dispose();
  }

  void submit() {
    final lines = [
      for (final line in patterns.text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    for (final line in lines) {
      try {
        RegExp(line);
      } on FormatException {
        setState(() => error = '正则写得不对：$line');
        return;
      }
    }
    if (lines.isEmpty && !strip) {
      setState(() => error = '至少写一条正则，或打开“先去掉括号”。');
      return;
    }
    Navigator.pop(
      context,
      _Edit(
        TitleRule.simple(
          uploaders: [
            for (final id in ups.text.split(RegExp(r'[,，、\s]+')))
              if (id.isNotEmpty) id,
          ],
          stripParenthesis: strip,
          patterns: lines,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final secondary = CupertinoColors.secondaryLabel.resolveFrom(context);
    Widget field(
      TextEditingController c,
      String label,
      String hint,
      int lines,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: secondary)),
        const SizedBox(height: 6),
        CupertinoTextField(
          controller: c,
          placeholder: hint,
          minLines: lines,
          maxLines: lines + 3,
          padding: const EdgeInsets.all(12),
          style: const TextStyle(fontSize: 16),
          placeholderStyle: TextStyle(fontSize: 15, color: secondary),
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
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  Expanded(
                    child: Text(
                      widget.current == null ? '添加规则' : '编辑规则',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: submit,
                    child: const Text(
                      '保存',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              field(ups, 'UP 主 ID（多个用逗号分隔，留空表示所有 UP 主）', '例如 94558176', 1),
              const SizedBox(height: 14),
              field(
                patterns,
                '正则（每行一条，按顺序尝试，取第一个括号里的内容）',
                r'例如 【.+】(.+) 或 《(.+)》',
                3,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Expanded(child: Text('先去掉最后一个括号及其后的内容')),
                  CupertinoSwitch(
                    value: strip,
                    onChanged: (v) => setState(() => strip = v),
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemRed,
                  ),
                ),
              ],
              if (widget.current != null) ...[
                const SizedBox(height: 6),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.pop(context, const _Edit(null)),
                  child: const Text(
                    '删除这条规则',
                    style: TextStyle(color: CupertinoColors.systemRed),
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
