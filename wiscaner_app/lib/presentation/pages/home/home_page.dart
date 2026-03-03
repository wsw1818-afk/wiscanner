import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../scanner/scanner_page.dart';
import '../settings/settings_page.dart';

/// 홈 화면: 스캔 이력 갤러리
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<FileSystemEntity> _scanFiles = [];
  bool _isLoading = true;

  // 다중 선택 모드
  bool _selectMode = false;
  final Set<String> _selectedPaths = {};

  @override
  void initState() {
    super.initState();
    _loadScanFiles();
  }

  Future<String> _getScanDirectory() async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final parts = extDir.path.split('Android');
        return '${parts[0]}Pictures${Platform.pathSeparator}WiScaner';
      }
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}${Platform.pathSeparator}WiScaner${Platform.pathSeparator}scans';
  }

  Future<void> _loadScanFiles() async {
    setState(() => _isLoading = true);
    try {
      final scanPath = await _getScanDirectory();
      final scanDir = Directory(scanPath);

      if (await scanDir.exists()) {
        final files = await scanDir
            .list()
            .where((entity) =>
                entity is File &&
                (entity.path.endsWith('.png') ||
                    entity.path.endsWith('.jpg') ||
                    entity.path.endsWith('.pdf')))
            .toList();

        files.sort((a, b) {
          final aStat = (a as File).statSync();
          final bStat = (b as File).statSync();
          return bStat.modified.compareTo(aStat.modified);
        });

        setState(() {
          _scanFiles = files;
          _isLoading = false;
        });
      } else {
        setState(() {
          _scanFiles = [];
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('스캔 파일 로드 실패: $e');
      setState(() {
        _scanFiles = [];
        _isLoading = false;
      });
    }
  }

  void _openScanner() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ScannerPage()))
        .then((_) => _loadScanFiles());
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedPaths.clear();
    });
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selectMode ? _buildSelectAppBar() : _buildNormalAppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _scanFiles.isEmpty
              ? _buildEmptyState()
              : _buildFileGrid(),
      floatingActionButton: _selectMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _openScanner,
              icon: const Icon(Icons.document_scanner),
              label: const Text('스캔'),
            ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('WiScaner'),
          if (_scanFiles.isNotEmpty)
            Text('${_scanFiles.length}개 파일',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      ),
      actions: [
        if (_scanFiles.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.checklist),
            onPressed: () => setState(() => _selectMode = true),
            tooltip: '선택',
          ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadScanFiles,
          tooltip: '새로고침',
        ),
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsPage()),
          ),
          tooltip: '설정',
        ),
      ],
    );
  }

  PreferredSizeWidget _buildSelectAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _exitSelectMode,
      ),
      title: Text('${_selectedPaths.length}개 선택'),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          onPressed: () {
            setState(() {
              if (_selectedPaths.length == _scanFiles.length) {
                _selectedPaths.clear();
              } else {
                _selectedPaths.addAll(_scanFiles.map((f) => f.path));
              }
            });
          },
          tooltip: '전체 선택',
        ),
        if (_selectedPaths.isNotEmpty) ...[
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareSelected,
            tooltip: '공유',
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: _deleteSelected,
            tooltip: '삭제',
          ),
        ],
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.document_scanner_outlined, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('스캔한 문서가 없습니다',
              style: TextStyle(fontSize: 18, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text('아래 버튼을 눌러 문서를 스캔하세요',
              style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _openScanner,
            icon: const Icon(Icons.document_scanner),
            label: const Text('첫 스캔 시작하기'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.65,
      ),
      itemCount: _scanFiles.length,
      itemBuilder: (context, index) {
        final file = _scanFiles[index] as File;
        final isPdf = file.path.endsWith('.pdf');
        final fileName = path.basenameWithoutExtension(file.path);
        final stat = file.statSync();
        final dateStr = DateFormat('MM/dd HH:mm').format(stat.modified);
        final sizeStr = _formatFileSize(stat.size);
        final isSelected = _selectedPaths.contains(file.path);

        return GestureDetector(
          onTap: () {
            if (_selectMode) {
              setState(() {
                if (isSelected) {
                  _selectedPaths.remove(file.path);
                } else {
                  _selectedPaths.add(file.path);
                }
              });
            } else {
              if (!isPdf) {
                _openImageViewer(file);
              } else {
                _showFileOptions(file);
              }
            }
          },
          onLongPress: () {
            if (!_selectMode) {
              setState(() {
                _selectMode = true;
                _selectedPaths.add(file.path);
              });
            }
          },
          child: Card(
            clipBehavior: Clip.antiAlias,
            elevation: isSelected ? 4 : 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: isSelected
                  ? const BorderSide(color: Colors.blue, width: 2)
                  : BorderSide.none,
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: isPdf
                          ? Container(
                              color: Colors.red[50],
                              child: Center(
                                child: Icon(Icons.picture_as_pdf,
                                    size: 48, color: Colors.red[400]),
                              ),
                            )
                          : Image.file(file, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: Colors.grey[200],
                                child: const Icon(Icons.broken_image, size: 48),
                              ),
                            ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
                      child: Text(
                        fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                      child: Text(
                        '$dateStr · $sizeStr',
                        maxLines: 1,
                        style: TextStyle(fontSize: 9, color: Colors.grey[500]),
                      ),
                    ),
                  ],
                ),
                if (_selectMode)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blue : Colors.black38,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openImageViewer(File file) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _ImageViewerPage(
          file: file,
          onDelete: () {
            _loadScanFiles();
            Navigator.pop(context);
          },
          onRename: () => _loadScanFiles(),
        ),
      ),
    );
  }

  void _showFileOptions(File file) {
    final fileName = path.basenameWithoutExtension(file.path);
    final stat = file.statSync();
    final dateStr = DateFormat('yyyy-MM-dd HH:mm').format(stat.modified);
    final sizeStr = _formatFileSize(stat.size);

    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(fileName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          const SizedBox(height: 4),
                          Text('$dateStr · $sizeStr', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.edit),
                title: const Text('이름 변경'),
                onTap: () {
                  Navigator.pop(ctx);
                  _renameFile(file);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('공유'),
                onTap: () {
                  Navigator.pop(ctx);
                  Share.shareXFiles([XFile(file.path)]);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('삭제', style: TextStyle(color: Colors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  _confirmDelete([file]);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _renameFile(File file) async {
    final ext = path.extension(file.path);
    final currentName = path.basenameWithoutExtension(file.path);
    final controller = TextEditingController(text: currentName);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이름 변경'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: '파일 이름',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      try {
        final dir = path.dirname(file.path);
        final newPath = '$dir${Platform.pathSeparator}$newName$ext';
        await file.rename(newPath);
        _loadScanFiles();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('이름이 "$newName"으로 변경되었습니다')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('이름 변경 실패: $e')),
          );
        }
      }
    }
  }

  Future<void> _confirmDelete(List<File> files) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('삭제 확인'),
        content: Text(files.length == 1
            ? '이 파일을 삭제하시겠습니까?'
            : '선택한 ${files.length}개 파일을 삭제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final f in files) {
        try {
          await f.delete();
        } catch (_) {}
      }
      _exitSelectMode();
      _loadScanFiles();
    }
  }

  void _shareSelected() {
    final xFiles = _selectedPaths.map((p) => XFile(p)).toList();
    Share.shareXFiles(xFiles);
  }

  void _deleteSelected() {
    final files = _selectedPaths.map((p) => File(p)).toList();
    _confirmDelete(files);
  }
}

/// 이미지 전체 화면 뷰어
class _ImageViewerPage extends StatelessWidget {
  final File file;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  const _ImageViewerPage({
    required this.file,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = path.basenameWithoutExtension(file.path);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(fileName, style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => Share.shareXFiles([XFile(file.path)]),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'rename') {
                await _rename(context);
              } else if (value == 'delete') {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('삭제 확인'),
                    content: const Text('이 파일을 삭제하시겠습니까?'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('삭제', style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await file.delete();
                  onDelete();
                }
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('이름 변경')),
              const PopupMenuItem(value: 'delete', child: Text('삭제', style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ext = path.extension(file.path);
    final currentName = path.basenameWithoutExtension(file.path);
    final controller = TextEditingController(text: currentName);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이름 변경'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: '파일 이름',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      try {
        final dir = path.dirname(file.path);
        await file.rename('$dir${Platform.pathSeparator}$newName$ext');
        onRename();
      } catch (_) {}
    }
  }
}
