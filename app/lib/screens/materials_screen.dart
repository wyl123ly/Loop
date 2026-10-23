import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';

class MaterialsScreen extends StatefulWidget {
  const MaterialsScreen({super.key, required this.active});

  final bool active;

  @override
  State<MaterialsScreen> createState() => _MaterialsScreenState();
}

class _MaterialsScreenState extends State<MaterialsScreen> {
  List<MaterialItem> _items = [];
  List<MaterialFolder> _folders = [];
  bool _loading = true;
  bool _uploading = false;
  String? _error;

  bool _importing = false;
  int? _deletingFolderId;
  final Set<int> _expandedFolders = {};
  final Set<String> _expandedDirs = {};
  int _importTotal = 0;
  int _importDone = 0;
  String _importCurrent = '';
  String? _importToken;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MaterialsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _load();
  }

  Future<void> _load() async {
    try {
      final items = await appState.api.materials();
      final folders = await appState.api.materialFolders();
      if (!mounted) return;
      setState(() {
        _items = items;
        _folders = folders;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _upload() async {
    const group = XTypeGroup(
      label: '资料',
      extensions: ['pdf', 'docx', 'pptx', 'txt', 'md'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      setState(() => _uploading = true);
      final result = await appState.api.upload(bytes, file.name);
      if (!mounted) return;
      setState(() => _uploading = false);
      await _load();
      if (!mounted) return;
      _snack('已解析 ${result['pages']} 页，共 ${result['chars']} 字');
    } catch (error) {
      if (mounted) setState(() => _uploading = false);
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _importFolder() async {
    final path = await getDirectoryPath();
    if (path == null || path.isEmpty) return;
    Map<String, dynamic> scan;
    try {
      scan = await appState.api.scanFolder(path);
    } catch (error) {
      _snack(error.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    final options = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (_) => _FolderImportDialog(scan: scan, path: path),
    );
    if (options == null) return;
    await _startImport(
      path,
      recursive: options['recursive'] == true,
      duplicate: (options['duplicate'] ?? 'skip').toString(),
    );
  }

  Future<void> _startImport(String path, {required bool recursive, required String duplicate}) async {
    final token = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() {
      _importing = true;
      _importDone = 0;
      _importTotal = 0;
      _importCurrent = '正在扫描…';
      _importToken = token;
    });
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    try {
      await for (final event in appState.api.importFolder(
        path: path,
        recursive: recursive,
        duplicate: duplicate,
        token: token,
      )) {
        if (!mounted) return;
        switch (event.event) {
          case 'start':
            setState(() {
              _importTotal = (event.data['total'] as num?)?.toInt() ?? 0;
              _importCurrent = '准备导入 ${event.data['name'] ?? ''}';
            });
          case 'progress':
            setState(() {
              _importDone = (event.data['done'] as num?)?.toInt() ?? _importDone;
            });
          case 'file':
            final status = (event.data['status'] ?? '').toString();
            if (status == 'imported') imported++;
            if (status == 'skipped') skipped++;
            if (status == 'failed') failed++;
            setState(() => _importCurrent = (event.data['relative'] ?? event.data['name'] ?? '').toString());
          case 'done':
            imported = (event.data['imported'] as num?)?.toInt() ?? imported;
            skipped = (event.data['skipped'] as num?)?.toInt() ?? skipped;
            failed = (event.data['failed'] as num?)?.toInt() ?? failed;
        }
      }
      await _load();
      if (!mounted) return;
      _snack('导入完成：$imported 个成功，$skipped 个跳过，$failed 个失败');
    } catch (error) {
      if (mounted) _snack(error.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _importToken = null;
          _importCurrent = '';
        });
      }
    }
  }

  Future<void> _cancelImport() async {
    final token = _importToken;
    if (token == null) return;
    try {
      await appState.api.cancelFolderImport(token);
    } catch (_) {}
  }

  void _snack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text, style: TextStyle(color: pal.toastFg)),
      backgroundColor: isError ? pal.danger : pal.toastBg,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 78,
          padding: const EdgeInsets.fromLTRB(32, 20, 28, 6),
          child: Row(
            children: [
              Text('资料', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              SizedBox(width: 10),
              Text('${_items.length} 份', style: TextStyle(fontSize: 12.5, color: pal.muted)),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: (_uploading || _importing) ? null : _importFolder,
                icon: const Icon(Icons.folder_outlined, size: 17),
                label: const Text('导入文件夹'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _uploading ? null : _upload,
                icon: _uploading
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.upload_file_rounded, size: 18),
                label: Text(_uploading ? '解析中…' : '上传资料'),
              ),
            ],
          ),
        ),
        if (_importing) _importBanner(),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _importBanner() {
    final progress = _importTotal > 0 ? (_importDone / _importTotal).clamp(0.0, 1.0) : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(28, 0, 28, 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: panelDecoration(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 16, color: pal.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _importTotal > 0 ? '导入文件夹 $_importDone / $_importTotal' : '正在准备导入…',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: pal.ink),
                ),
              ),
              TextButton(onPressed: _cancelImport, child: const Text('取消')),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: progress, minHeight: 5),
            ),
          ],
          if (_importCurrent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_importCurrent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: pal.muted)),
            ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: pal.muted, fontSize: 13)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty && _folders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_outlined, size: 40, color: pal.faint),
            const SizedBox(height: 12),
            const Text('还没有资料', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('上传文件，或直接导入电脑上已有的整个文件夹。',
                style: TextStyle(fontSize: 12.5, color: pal.muted)),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _importFolder,
                  icon: const Icon(Icons.folder_outlined, size: 17),
                  label: const Text('导入文件夹'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: const Text('选一个文件'),
                ),
              ],
            ),
          ],
        ),
      );
    }
    final children = <Widget>[];
    final grouped = _items.where((item) => item.folderId > 0).toList();
    for (final folder in _folders) {
      final files = grouped.where((item) => item.folderId == folder.id).toList();
      children.add(_folderHeader(folder, files.length, files));
      if (_expandedFolders.contains(folder.id)) {
        children.addAll(_renderTree(folder, _buildTree(files), 1));
      }
    }
    final loose = _items.where((item) => item.folderId == 0).toList();
    if (loose.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
        child: Text('单独上传',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: pal.muted)),
      ));
      for (final item in loose) {
        children.add(_materialTile(item));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 40),
      children: children,
    );
  }

  _Dir _buildTree(List<MaterialItem> files) {
    final root = _Dir('', '');
    for (final item in files) {
      final relative = item.relativePath.isNotEmpty ? item.relativePath : item.name;
      final parts = relative.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      var node = root;
      var dirPath = '';
      for (var i = 0; i < parts.length - 1; i++) {
        dirPath = dirPath.isEmpty ? parts[i] : '$dirPath/${parts[i]}';
        node = node.dirs.putIfAbsent(parts[i], () => _Dir(parts[i], dirPath));
      }
      node.files.add(item);
    }
    return root;
  }

  List<Widget> _renderTree(MaterialFolder folder, _Dir node, int depth) {
    final widgets = <Widget>[];
    final dirs = node.dirs.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (final dir in dirs) {
      final key = _dirKey(folder.id, dir.path);
      final expanded = _expandedDirs.contains(key);
      widgets.add(_dirTile(dir, depth, expanded, () {
        setState(() {
          if (!_expandedDirs.remove(key)) _expandedDirs.add(key);
        });
      }));
      if (expanded) {
        widgets.addAll(_renderTree(folder, dir, depth + 1));
      }
    }
    final files = node.files.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (final file in files) {
      widgets.add(_materialTile(file, depth: depth));
    }
    return widgets;
  }

  String _dirKey(int folderId, String path) => '$folderId/$path';

  Set<String> _allDirKeys(int folderId, List<MaterialItem> files) {
    final keys = <String>{};
    for (final item in files) {
      final relative = item.relativePath.isNotEmpty ? item.relativePath : item.name;
      final parts = relative.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
      var path = '';
      for (var i = 0; i < parts.length - 1; i++) {
        path = path.isEmpty ? parts[i] : '$path/${parts[i]}';
        keys.add(_dirKey(folderId, path));
      }
    }
    return keys;
  }

  bool _hasExpanded(int folderId, List<MaterialItem> files) {
    final prefix = '$folderId/';
    return _expandedFolders.contains(folderId) ||
        _expandedDirs.any((key) => key.startsWith(prefix));
  }

  void _toggleAll(MaterialFolder folder, List<MaterialItem> files) {
    final prefix = '${folder.id}/';
    final expanded = _hasExpanded(folder.id, files);
    setState(() {
      if (expanded) {
        _expandedFolders.remove(folder.id);
        _expandedDirs.removeWhere((key) => key.startsWith(prefix));
      } else {
        _expandedFolders.add(folder.id);
        _expandedDirs.addAll(_allDirKeys(folder.id, files));
      }
    });
  }

  Widget _dirTile(_Dir dir, int depth, bool expanded, VoidCallback onTap) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, top: 1, bottom: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Row(
              children: [
                SizedBox(
                  width: 15,
                  child: Text(
                    expanded ? '▾' : '▸',
                    style: TextStyle(fontSize: 14, height: 1, color: pal.muted),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.folder_outlined, size: 15, color: pal.muted),
                const SizedBox(width: 6),
                Text(dir.name,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: pal.muted)),
                const SizedBox(width: 6),
                Text('${_countFiles(dir)} 份', style: TextStyle(fontSize: 10.5, color: pal.faint)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int _countFiles(_Dir dir) {
    var count = dir.files.length;
    for (final child in dir.dirs.values) {
      count += _countFiles(child);
    }
    return count;
  }

  Widget _folderHeader(MaterialFolder folder, int count, List<MaterialItem> files) {
    final expanded = _expandedFolders.contains(folder.id);
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: panelDecoration(radius: 16),
      child: Row(
        children: [
          IconButton(
            tooltip: expanded ? '收起文件夹' : '展开文件夹',
            onPressed: () {
              setState(() {
                if (!_expandedFolders.remove(folder.id)) _expandedFolders.add(folder.id);
              });
            },
            icon: Text(
              expanded ? '▾' : '▸',
              style: TextStyle(fontSize: 17, height: 1, color: pal.muted),
            ),
          ),
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: pal.chip, borderRadius: BorderRadius.circular(9)),
            child: Icon(Icons.folder_outlined, size: 18, color: pal.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(folder.name,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: pal.ink)),
                Text(folder.rootPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: pal.muted)),
              ],
            ),
          ),
          Text('$count 份', style: TextStyle(fontSize: 11, color: pal.muted)),
          TextButton(
            onPressed: () => _toggleAll(folder, files),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(_hasExpanded(folder.id, files) ? '全部收起' : '全部展开',
                style: TextStyle(fontSize: 11, color: pal.muted)),
          ),
          if (_deletingFolderId == folder.id)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else ...[
            IconButton(
              tooltip: '重新导入',
              onPressed: _importing
                  ? null
                  : () => _startImport(folder.rootPath, recursive: true, duplicate: 'skip'),
              icon: Icon(Icons.refresh_rounded, size: 17, color: pal.muted),
            ),
            IconButton(
              tooltip: '删除整个文件夹',
              onPressed: () => _confirmDeleteFolder(folder),
              icon: Icon(Icons.delete_outline_rounded, size: 18, color: pal.faint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _materialTile(MaterialItem item, {int depth = 0}) {
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, bottom: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showPreview(item),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: panelDecoration(radius: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: pal.chip, borderRadius: BorderRadius.circular(8)),
                  child: Icon(_icon(item.kind), size: 17, color: pal.accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.ink)),
                      const SizedBox(height: 2),
                      Text(
                        '${item.kind.toUpperCase()} · ${item.pages} 页 · ${_formatChars(item.chars)}',
                        style: TextStyle(fontSize: 11, color: pal.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () => _confirmDelete(item),
                  icon: Icon(Icons.delete_outline_rounded, size: 17, color: pal.faint),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteFolder(MaterialFolder folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除文件夹资料'),
        content: Text('删除「${folder.name}」下的 ${folder.fileCount} 份资料及其索引？不会删除原文件夹。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: pal.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _deletingFolderId = folder.id);
    try {
      await appState.api.deleteMaterialFolder(folder.id);
      await _load();
      _expandedFolders.remove(folder.id);
      _expandedDirs.removeWhere((key) => key.startsWith('${folder.id}/'));
      _snack('已删除「${folder.name}」的资料');
    } catch (error) {
      _snack(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _deletingFolderId = null);
    }
  }

  IconData _icon(String kind) {
    return switch (kind.toLowerCase()) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'pptx' => Icons.slideshow_outlined,
      'docx' => Icons.description_outlined,
      _ => Icons.article_outlined,
    };
  }

  String _formatChars(int chars) {
    if (chars > 10000) return '${(chars / 1000).toStringAsFixed(1)}k 字';
    return '$chars 字';
  }

  Future<void> _showPreview(MaterialItem item) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.name, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 4),
            Text('${item.pages} 页 · ${_formatChars(item.chars)}',
                style: TextStyle(fontSize: 11.5, color: pal.muted)),
          ],
        ),
        content: SizedBox(
          width: 720,
          height: 460,
          child: FutureBuilder<Map<String, dynamic>>(
            future: appState.api.materialPreview(item.id),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator(strokeWidth: 2.2));
              }
              if (snapshot.hasError) {
                return Text(snapshot.error.toString(),
                    style: TextStyle(fontSize: 12.5, color: pal.danger));
              }
              final text = (snapshot.data?['text'] ?? '') as String;
              return SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: TextStyle(fontSize: 13, height: 1.75, color: pal.ink),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(MaterialItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除资料'),
        content: Text('「${item.name}」的索引会一起删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: pal.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await appState.api.deleteMaterial(item.id);
      await _load();
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }
}

class _FolderImportDialog extends StatefulWidget {
  const _FolderImportDialog({required this.scan, required this.path});

  final Map<String, dynamic> scan;
  final String path;

  @override
  State<_FolderImportDialog> createState() => _FolderImportDialogState();
}

class _FolderImportDialogState extends State<_FolderImportDialog> {
  late Map<String, dynamic> _scan = widget.scan;
  bool _recursive = true;
  bool _scanning = false;
  String _duplicate = 'skip';

  Future<void> _rescan(bool recursive) async {
    setState(() {
      _recursive = recursive;
      _scanning = true;
    });
    try {
      final scan = await appState.api.scanFolder(widget.path, recursive: recursive);
      if (mounted) setState(() => _scan = scan);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = (_scan['files'] as List? ?? []).whereType<Map>().toList();
    final supported = files.where((file) => file['supported'] == true).toList();
    final total = files.length;
    final bytes = (_scan['bytes'] as num?)?.toInt() ?? 0;
    return AlertDialog(
      title: const Text('导入文件夹'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((_scan['name'] ?? '').toString(),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: pal.ink)),
            Text((_scan['root'] ?? '').toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: pal.muted)),
            const SizedBox(height: 12),
            Text(
              '共 $total 个文件，可导入 ${supported.length} 个，跳过 ${total - supported.length} 个 · ${_size(bytes)}',
              style: TextStyle(fontSize: 12.5, color: pal.ink),
            ),
            if (_scan['truncated'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('文件很多，预览只显示前 1000 个。',
                    style: TextStyle(fontSize: 11, color: pal.warm)),
              ),
            if (_scanning)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('包含子文件夹', style: TextStyle(fontSize: 13)),
              value: _recursive,
              onChanged: _scanning ? null : _rescan,
            ),
            Row(
              children: [
                Text('重复文件', style: TextStyle(fontSize: 13, color: pal.ink)),
                const Spacer(),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'skip', label: Text('跳过')),
                    ButtonSegment(value: 'update', label: Text('更新')),
                  ],
                  selected: {_duplicate},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) => setState(() => _duplicate = value.first),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('只支持 PDF/DOCX/PPTX/TXT/MD；文件数量不限制，单个文件 ≤30MB。',
                style: TextStyle(fontSize: 11, color: pal.muted)),
            if (supported.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('将导入：',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: pal.muted)),
              const SizedBox(height: 4),
              SizedBox(
                height: 120,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final file in supported.take(8))
                        Text('· ${file['relative']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: pal.ink)),
                      if (supported.length > 8)
                        Text('… 还有 ${supported.length - 8} 个',
                            style: TextStyle(fontSize: 11, color: pal.muted)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: supported.isEmpty
              ? null
              : () => Navigator.pop(context, {
                    'recursive': _recursive,
                    'duplicate': _duplicate,
                  }),
          child: Text('导入 ${supported.length} 个'),
        ),
      ],
    );
  }

  String _size(int bytes) {
    if (bytes > 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    if (bytes > 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}


class _Dir {
  _Dir(this.name, this.path);
  final String name;
  final String path;
  final Map<String, _Dir> dirs = {};
  final List<MaterialItem> files = [];
}
