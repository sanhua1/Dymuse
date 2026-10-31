import 'dart:math';
import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import 'catalog.dart';

/// 发现页范围与分类；分类来自上游目录，不靠手写分类猜测。
/// 歌单广场只按热门排序：上游 order=new 对所有分类均返回空列表（2026-10-29 实测）。
class DiscoveryControls extends StatelessWidget {
  const DiscoveryControls({
    super.key,
    required this.catalog,
    required this.selected,
    required this.category,
    required this.onSelect,
    required this.onCategory,
  });
  final Catalog catalog;
  final DiscoverSection selected;
  final String category;
  final ValueChanged<DiscoverSection> onSelect;
  final ValueChanged<String> onCategory;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (DymuseTokens.apple)
          GlassChoiceRow<DiscoverSection>(
            values: DiscoverSection.values,
            selected: selected,
            labelOf: (section) => section.label,
            onSelect: (value) {
              if (value != selected) onSelect(value);
            },
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: CupertinoSlidingSegmentedControl<DiscoverSection>(
              groupValue: selected,
              children: {
                for (final section in DiscoverSection.values)
                  section: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    child: Text(section.label),
                  ),
              },
              onValueChanged: (value) {
                if (value != null && value != selected) onSelect(value);
              },
            ),
          ),
        if (selected == DiscoverSection.playlists) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _CategoryButton(
                label: '选择歌单分类',
                onPressed: () async {
                  final result = await showCupertinoModalPopup<String>(
                    context: context,
                    builder: (context) => Center(
                      child: SizedBox(
                        width: min(480, MediaQuery.sizeOf(context).width - 32),
                        height: MediaQuery.sizeOf(context).height * .75,
                        child: _CategoryPicker(
                          catalog: catalog,
                          selected: category,
                        ),
                      ),
                    ),
                  );
                  if (result != null && context.mounted) onCategory(result);
                },
                child: Text('$category ▾'),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

/// 分类入口：Apple 平台为玻璃胶囊，Windows 保持 ActionButton。
class _CategoryButton extends StatelessWidget {
  const _CategoryButton({
    required this.label,
    required this.onPressed,
    required this.child,
  });
  final String label;
  final VoidCallback onPressed;
  final Widget child;
  @override
  Widget build(BuildContext context) => DymuseTokens.apple
      ? GlassPillButton(
          label: label,
          text: (child as Text).data,
          onPressed: onPressed,
        )
      : ActionButton(label: label, onPressed: onPressed, child: child);
}

class _CategoryPicker extends StatefulWidget {
  const _CategoryPicker({required this.catalog, required this.selected});
  final Catalog catalog;
  final String selected;
  @override
  State<_CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<_CategoryPicker> {
  Map<String, List<String>> groups = {};
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  /// 失败留在分类面板重试；上游返回的分组和名称直接作为筛选值。
  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    final session = widget.catalog.api.token;
    try {
      final data =
          await widget.catalog.api.get('/netease/playlist/catlist') as Json;
      if (!mounted || session != widget.catalog.api.token) return;
      if (data['sub'] is! List || data['categories'] is! Map) {
        throw const ApiException('CATEGORIES_UNAVAILABLE', '歌单分类暂不可用。');
      }
      final result = <String, List<String>>{};
      for (final item in data['sub'] as List) {
        final name = item['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        final group =
            data['categories'][item['category'].toString()]?.toString() ?? '其他';
        (result[group] ??= []).add(name);
      }
      groups = result;
    } catch (failure) {
      if (mounted) error = readableError(failure);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget choice(String name) => CupertinoButton(
    onPressed: () => Navigator.pop(context, name),
    child: Row(
      children: [
        Expanded(
          child: Text(name, style: TextStyle(color: DymuseTokens.ink(context))),
        ),
        if (widget.selected == name)
          const Icon(CupertinoIcons.check_mark, size: 18),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => CupertinoPopupSurface(
    child: ColoredBox(
      color: DymuseTokens.surface(context),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '歌单分类',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ActionButton(
                    label: '关闭分类',
                    icon: CupertinoIcons.xmark,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : error != null
                  ? StatusMessage(
                      title: '分类暂不可用',
                      message: error!,
                      action: ActionButton(label: '重试', onPressed: load),
                    )
                  : ListView(
                      children: [
                        choice('全部'),
                        for (final group in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                            child: Text(
                              group.key,
                              style: DymuseTokens.caption.copyWith(
                                color: DymuseTokens.secondary(context),
                              ),
                            ),
                          ),
                          for (final name in group.value) choice(name),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
