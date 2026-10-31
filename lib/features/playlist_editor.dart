import 'package:flutter/cupertino.dart';
import '../core/api_client.dart';
import '../design_system/components.dart';
import '../design_system/tokens.dart';
import '../platform/desktop_window.dart';
import 'browse_page.dart';
import 'catalog.dart';
import 'search_controls.dart';

/// 完整读取可见条目后才允许保存；隐藏条目由后端保留，版本冲突不覆盖。
class PlaylistDraft extends ChangeNotifier {
  PlaylistDraft(this.catalog, Collection? playlist)
    : id = playlist?.id,
      name = playlist?.title ?? '',
      _session = catalog.api.token,
      _server = catalog.api.server;
  final Catalog catalog;
  final String? _session;
  final String _server;
  String? id, revision, error;
  String name, description = '';
  List<Track> tracks = [];
  int unavailableCount = 0;
  bool loading = false,
      loaded = false,
      writing = false,
      dirty = false,
      _disposed = false;
  bool get active =>
      !_disposed &&
      catalog.api.token == _session &&
      catalog.api.server == _server;

  Future<void> load() async {
    if (!active || loading || writing) return;
    loading = true;
    loaded = false;
    error = null;
    notifyListeners();
    try {
      if (id == null) {
        name = '';
        description = '';
        tracks = [];
        unavailableCount = 0;
        dirty = false;
        loaded = true;
        return;
      }
      final items = <Track>[];
      String? version;
      var offset = 0;
      while (true) {
        final data =
            await catalog.api.get('/bilibili/playlists/$id', {
                  'offset': offset,
                  'limit': 500,
                })
                as Json;
        if (!active) return;
        final current = data['revision']?.toString();
        if (current == null || version != null && version != current) {
          throw const ApiException('PLAYLIST_CHANGED', '载入期间歌单发生变化，请重新载入。');
        }
        version = current;
        final raw = (data['items'] as List).cast<Json>();
        items.addAll(raw.map(Track.bilibili));
        final total = (data['total'] as num).toInt();
        if (total > 10000) {
          throw const ApiException('PLAYLIST_TOO_LARGE', '歌单超过编辑上限。');
        }
        name = data['name'].toString();
        description = data['description']?.toString() ?? '';
        unavailableCount = (data['unavailableCount'] as num?)?.toInt() ?? 0;
        offset += raw.length;
        if (offset >= total) break;
        if (raw.isEmpty) {
          throw const ApiException('PLAYLIST_INCOMPLETE', '歌单未完整载入，请重试。');
        }
      }
      if (!active) return;
      revision = version;
      tracks = items;
      loaded = true;
      dirty = false;
    } catch (failure) {
      if (active) error = readableError(failure);
    } finally {
      if (active) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void metadata(String title, String detail) {
    name = title;
    description = detail;
    dirty = true;
    notifyListeners();
  }

  void add(Iterable<Track> items) {
    final known = tracks.map((t) => t.id).toSet();
    tracks.addAll(
      items.where((t) => t.mode == MusicMode.bilibili && known.add(t.id)),
    );
    dirty = true;
    notifyListeners();
  }

  void remove(int index) {
    tracks.removeAt(index);
    dirty = true;
    notifyListeners();
  }

  void reorder(int from, int to) {
    if (to > from) to--;
    if (from == to) return;
    final track = tracks.removeAt(from);
    tracks.insert(to, track);
    dirty = true;
    notifyListeners();
  }

  /// 草稿一次提交；失败保留编辑内容，带旧版本避免覆盖其他设备修改。
  Future<bool> save() async {
    if (!active || !loaded || writing) return false;
    if (name.trim().isEmpty) {
      error = '请输入歌单名称。';
      notifyListeners();
      return false;
    }
    writing = true;
    error = null;
    notifyListeners();
    try {
      final body = {
        'name': name.trim(),
        'description': description,
        'trackIds': tracks.map((t) => t.id).toList(),
        if (id != null) 'revision': revision,
        if (id != null) 'preserveUnavailable': true,
      };
      final data =
          await (id == null
                  ? catalog.api.post('/bilibili/playlists', body)
                  : catalog.api.put('/bilibili/playlists/$id', body))
              as Json;
      if (!active) return false;
      if (data['id'] == null || data['revision'] == null) {
        throw const ApiException('PLAYLIST_SAVE_FAILED', '服务器未确认保存结果。');
      }
      id = data['id'].toString();
      revision = data['revision'].toString();
      dirty = false;
      return true;
    } catch (failure) {
      if (active) error = readableError(failure);
      return false;
    } finally {
      if (active) {
        writing = false;
        notifyListeners();
      }
    }
  }

  Future<bool> archive() async {
    if (!active || id == null || revision == null || !loaded || writing) {
      return false;
    }
    writing = true;
    error = null;
    notifyListeners();
    try {
      final data = await catalog.api.post('/bilibili/playlists/$id/archive', {
        'revision': revision,
      });
      if (!active) return false;
      if (data['ok'] != true) {
        throw const ApiException('PLAYLIST_ARCHIVE_FAILED', '服务器未确认归档结果。');
      }
      dirty = false;
      return true;
    } catch (failure) {
      if (active) error = readableError(failure);
      return false;
    } finally {
      if (active) {
        writing = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class PlaylistEditorPage extends StatefulWidget {
  const PlaylistEditorPage({
    super.key,
    required this.catalog,
    this.playlist,
    this.window,
  });
  final Catalog catalog;
  final Collection? playlist;
  final DesktopWindow? window;
  @override
  State<PlaylistEditorPage> createState() => _PlaylistEditorPageState();
}

class _PlaylistEditorPageState extends State<PlaylistEditorPage> {
  late final draft = PlaylistDraft(widget.catalog, widget.playlist);
  final name = TextEditingController(), description = TextEditingController();
  bool allowPop = false;
  @override
  void initState() {
    super.initState();
    draft.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    await draft.load();
    if (!mounted) return;
    name.text = draft.name;
    description.text = draft.description;
  }

  @override
  void dispose() {
    draft.removeListener(changed);
    draft.dispose();
    name.dispose();
    description.dispose();
    super.dispose();
  }

  Future<bool> confirm(String title, String message, String action) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> close({bool changed = false}) async {
    if (draft.writing) return;
    if (!changed &&
        draft.dirty &&
        !await confirm('放弃修改？', '未保存的歌单编辑将被放弃。', '放弃修改')) {
      return;
    }
    if (!mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, changed);
    });
  }

  Future<void> addSongs() async {
    final result = await Navigator.of(context).push<List<Track>>(
      CupertinoPageRoute(
        builder: (_) => _PrivateTrackPicker(
          catalog: widget.catalog,
          window: widget.window,
          existing: draft.tracks.map((t) => t.id).toSet(),
        ),
      ),
    );
    if (mounted && draft.active && result != null) draft.add(result);
  }

  @override
  Widget build(BuildContext context) => _EditorWindow(
    window: widget.window,
    child: PopScope<bool>(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: CupertinoPageScaffold(
        backgroundColor: DymuseTokens.background(context),
        navigationBar: CupertinoNavigationBar(
          middle: Text(widget.playlist == null ? '新建私人歌单' : '编辑私人歌单'),
          leading: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: draft.writing ? null : close,
            child: const Text('取消'),
          ),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: !draft.loaded || draft.writing
                ? null
                : () async {
                    if (await draft.save()) await close(changed: true);
                  },
            child: const Text('保存'),
          ),
        ),
        child: SafeArea(
          child: draft.loading
              ? const Center(child: CupertinoActivityIndicator())
              : !draft.loaded
              ? StatusMessage(
                  title: '无法载入歌单',
                  message: draft.error ?? '请稍后重试。',
                  action: ActionButton(label: '重试', onPressed: load),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CupertinoTextField(
                            controller: name,
                            placeholder: '歌单名称',
                            maxLength: 200,
                            enabled: !draft.writing,
                            padding: const EdgeInsets.all(12),
                            onChanged: (_) =>
                                draft.metadata(name.text, description.text),
                          ),
                          const SizedBox(height: 8),
                          CupertinoTextField(
                            controller: description,
                            placeholder: '简介（可选）',
                            maxLength: 2000,
                            minLines: 1,
                            maxLines: 2,
                            enabled: !draft.writing,
                            padding: const EdgeInsets.all(12),
                            onChanged: (_) =>
                                draft.metadata(name.text, description.text),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 16,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ActionButton(
                                label: '添加歌曲',
                                icon: CupertinoIcons.plus,
                                onPressed: draft.writing ? null : addSongs,
                                child: const ExcludeSemantics(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(CupertinoIcons.plus, size: 18),
                                      SizedBox(width: 8),
                                      Text('添加歌曲'),
                                    ],
                                  ),
                                ),
                              ),
                              Text(
                                '${draft.tracks.length} 首可见歌曲${draft.unavailableCount > 0 ? ' · ${draft.unavailableCount} 首隐藏条目将保留' : ''}',
                                style: DymuseTokens.caption,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: draft.tracks.isEmpty
                          ? const Center(child: Text('添加一些歌曲，组成你的歌单。'))
                          : ReorderableList(
                              itemCount: draft.tracks.length,
                              onReorder: draft.writing
                                  ? (_, _) {}
                                  : draft.reorder,
                              itemBuilder: (context, index) {
                                final track = draft.tracks[index];
                                return Padding(
                                  key: ValueKey(track.id),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      ReorderableDragStartListener(
                                        index: index,
                                        enabled: !draft.writing,
                                        child: const SizedBox(
                                          width: 44,
                                          height: 44,
                                          child: Icon(
                                            CupertinoIcons.line_horizontal_3,
                                            size: 18,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              track.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              track.artist,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: DymuseTokens.caption,
                                            ),
                                          ],
                                        ),
                                      ),
                                      ActionButton(
                                        label: '上移${track.title}',
                                        icon: CupertinoIcons.arrow_up,
                                        compact: true,
                                        onPressed: draft.writing || index == 0
                                            ? null
                                            : () => draft.reorder(
                                                index,
                                                index - 1,
                                              ),
                                      ),
                                      ActionButton(
                                        label: '下移${track.title}',
                                        icon: CupertinoIcons.arrow_down,
                                        compact: true,
                                        onPressed:
                                            draft.writing ||
                                                index == draft.tracks.length - 1
                                            ? null
                                            : () => draft.reorder(
                                                index,
                                                index + 2,
                                              ),
                                      ),
                                      ActionButton(
                                        label: '从歌单移除${track.title}',
                                        icon: CupertinoIcons.minus_circle,
                                        compact: true,
                                        onPressed: draft.writing
                                            ? null
                                            : () => draft.remove(index),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    if (draft.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          draft.error!,
                          style: TextStyle(
                            color: CupertinoColors.destructiveRed.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                      child: Wrap(
                        spacing: 16,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (widget.playlist != null)
                            ActionButton(
                              label: '归档歌单',
                              onPressed: draft.writing
                                  ? null
                                  : () async {
                                      if (await confirm(
                                            '归档歌单？',
                                            '归档后不再显示在我的歌单。历史和音频文件保留。',
                                            '归档',
                                          ) &&
                                          await draft.archive()) {
                                        await close(changed: true);
                                      }
                                    },
                            ),
                          ActionButton(
                            label: '重新载入歌单',
                            onPressed: draft.writing
                                ? null
                                : () async {
                                    if (!draft.dirty ||
                                        await confirm(
                                          '重新载入？',
                                          '未保存的修改将被放弃。',
                                          '重新载入',
                                        )) {
                                      await load();
                                    }
                                  },
                          ),
                          if (draft.writing) const CupertinoActivityIndicator(),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );
}

/// 编辑和选歌是独立页面，仍保留桌面窗口控制与拖动区域。
class _EditorWindow extends StatelessWidget {
  const _EditorWindow({required this.window, required this.child});
  final DesktopWindow? window;
  final Widget child;
  @override
  Widget build(BuildContext context) => window == null
      ? child
      : Column(
          children: [
            WindowTitleBar(window: window!),
            Expanded(child: child),
          ],
        );
}

/// 选歌只修改草稿；搜索和翻页限定在私人曲库，不即时写入歌单。
class _PrivateTrackPicker extends StatefulWidget {
  const _PrivateTrackPicker({
    required this.catalog,
    required this.existing,
    this.window,
  });
  final Catalog catalog;
  final Set<String> existing;
  final DesktopWindow? window;
  @override
  State<_PrivateTrackPicker> createState() => _PrivateTrackPickerState();
}

class _PrivateTrackPickerState extends State<_PrivateTrackPicker> {
  late final browser = BrowseState(MusicMode.bilibili, widget.catalog);
  final query = TextEditingController(), focus = FocusNode();
  final selected = <String, Track>{};
  @override
  void initState() {
    super.initState();
    // 未搜索时先列出红心歌曲，方便直接挑选。
    browser.section = 'favorites';
    browser.load();
  }

  @override
  void dispose() {
    browser.dispose();
    query.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _EditorWindow(
    window: widget.window,
    child: CupertinoPageScaffold(
      backgroundColor: DymuseTokens.background(context),
      navigationBar: CupertinoNavigationBar(
        middle: const Text('添加歌曲'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(context, selected.values.toList()),
          child: Text('添加 ${selected.length} 首'),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: DymuseSearchField(
                controller: query,
                focusNode: focus,
                placeholder: '搜索哔哩哔哩',
                onSearch: (text) => browser.navigate('search', text: text),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: browser,
                builder: (_, _) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => browser.loadNearEnd(),
                  );
                  if (!browser.loaded && browser.loading) {
                    return const Center(child: CupertinoActivityIndicator());
                  }
                  return NotificationListener<ScrollNotification>(
                    onNotification: (_) {
                      browser.loadNearEnd();
                      return false;
                    },
                    child: ListView.builder(
                      controller: browser.scroll,
                      itemCount: browser.page.tracks.length + 1,
                      itemBuilder: (context, index) {
                        if (index == browser.page.tracks.length) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                if (browser.loading)
                                  const CupertinoActivityIndicator(),
                                if (browser.error != null) ...[
                                  Text(browser.error!),
                                  ActionButton(
                                    label: '重试',
                                    onPressed: browser.retry,
                                  ),
                                ],
                                if (!browser.loading &&
                                    browser.error == null &&
                                    browser.page.tracks.isEmpty)
                                  const Text('没有找到歌曲'),
                              ],
                            ),
                          );
                        }
                        final track = browser.page.tracks[index],
                            existing = widget.existing.contains(
                              browser.page.tracks[index].id,
                            );
                        final checked =
                            existing || selected.containsKey(track.id);
                        return CupertinoButton(
                          onPressed: existing
                              ? null
                              : () => setState(() {
                                  if (checked) {
                                    selected.remove(track.id);
                                  } else {
                                    selected[track.id] = track;
                                  }
                                }),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      track.title,
                                      style: TextStyle(
                                        color: DymuseTokens.ink(context),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      existing ? '已在歌单中' : track.artist,
                                      style: DymuseTokens.caption,
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                checked
                                    ? CupertinoIcons.check_mark_circled_solid
                                    : CupertinoIcons.circle,
                                size: 22,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
