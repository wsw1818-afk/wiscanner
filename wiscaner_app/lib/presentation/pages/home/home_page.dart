import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';
import '../scanner/scanner_page.dart';
import '../settings/settings_page.dart';
import 'pdf_edit_page.dart';
import 'pdf_viewer_page.dart';
import '../../../core/services/document_scanner_service.dart';

/// 파일 분류 필터
enum FileCategory { all, images, pdfs }

/// 홈 화면: 스캔 이력 갤러리 + 폴더 분류
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<FileSystemEntity> _allFiles = [];
  bool _isLoading = true;
  FileCategory _category = FileCategory.all;

  // 다중 선택 모드 (List로 클릭 순서 보존)
  bool _selectMode = false;
  final List<String> _selectedPaths = [];

  List<FileSystemEntity> get _filteredFiles {
    switch (_category) {
      case FileCategory.images:
        return _allFiles.where((f) =>
            f.path.endsWith('.png') || f.path.endsWith('.jpg')).toList();
      case FileCategory.pdfs:
        return _allFiles.where((f) => f.path.endsWith('.pdf')).toList();
      case FileCategory.all:
        return _allFiles;
    }
  }

  int get _imageCount => _allFiles.where((f) =>
      f.path.endsWith('.png') || f.path.endsWith('.jpg')).length;
  int get _pdfCount => _allFiles.where((f) => f.path.endsWith('.pdf')).length;

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
        return '${parts[0]}Pictures${Platform.pathSeparator}WiScanner';
      }
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}${Platform.pathSeparator}WiScanner${Platform.pathSeparator}scans';
  }

  Future<String> _getPdfDirectory() async {
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        return '${extDir.path}${Platform.pathSeparator}pdfs';
      }
    }
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}${Platform.pathSeparator}WiScanner${Platform.pathSeparator}pdfs';
  }

  Future<void> _loadScanFiles() async {
    setState(() => _isLoading = true);
    try {
      final allFiles = <FileSystemEntity>[];

      // 이미지 디렉토리 (Pictures/WiScanner)
      final scanPath = await _getScanDirectory();
      final scanDir = Directory(scanPath);
      if (await scanDir.exists()) {
        await for (final entity in scanDir.list()) {
          if (entity is File &&
              (entity.path.endsWith('.png') || entity.path.endsWith('.jpg'))) {
            allFiles.add(entity);
          }
        }
      }

      // PDF 디렉토리 (앱 전용/pdfs)
      final pdfPath = await _getPdfDirectory();
      final pdfDir = Directory(pdfPath);
      if (await pdfDir.exists()) {
        await for (final entity in pdfDir.list()) {
          if (entity is File && entity.path.endsWith('.pdf')) {
            allFiles.add(entity);
          }
        }
      }

      allFiles.sort((a, b) {
        final aStat = (a as File).statSync();
        final bStat = (b as File).statSync();
        return bStat.modified.compareTo(aStat.modified);
      });

      setState(() {
        _allFiles = allFiles;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('스캔 파일 로드 실패: $e');
      setState(() {
        _allFiles = [];
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
    final scanFiles = _filteredFiles;

    return Scaffold(
      appBar: _selectMode ? _buildSelectAppBar() : _buildNormalAppBar(),
      body: Column(
        children: [
          // 카테고리 필터 탭
          if (_allFiles.isNotEmpty && !_selectMode) _buildCategoryTabs(),

          // 파일 그리드
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : scanFiles.isEmpty
                    ? _buildEmptyState()
                    : _buildFileGrid(scanFiles),
          ),
        ],
      ),
      floatingActionButton: _selectMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _openScanner,
              icon: const Icon(Icons.document_scanner),
              label: const Text('스캔'),
            ),
    );
  }

  Widget _buildCategoryTabs() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _buildCategoryChip('전체', FileCategory.all, _allFiles.length),
          const SizedBox(width: 8),
          _buildCategoryChip('이미지', FileCategory.images, _imageCount, Icons.image),
          const SizedBox(width: 8),
          _buildCategoryChip('PDF', FileCategory.pdfs, _pdfCount, Icons.picture_as_pdf),
        ],
      ),
    );
  }

  Widget _buildCategoryChip(String label, FileCategory cat, int count, [IconData? icon]) {
    final isSelected = _category == cat;
    return GestureDetector(
      onTap: () => setState(() => _category = cat),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey[200],
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14,
                  color: isSelected ? Colors.white : Colors.grey[700]),
              const SizedBox(width: 4),
            ],
            Text(
              '$label ($count)',
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? Colors.white : Colors.grey[700],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildNormalAppBar() {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('WiScanner'),
          if (_allFiles.isNotEmpty)
            Text('${_allFiles.length}개 파일',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      ),
      actions: [
        if (_allFiles.isNotEmpty)
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
              final files = _filteredFiles;
              if (_selectedPaths.length == files.length) {
                _selectedPaths.clear();
              } else {
                _selectedPaths.clear();
                _selectedPaths.addAll(files.map((f) => f.path));
              }
            });
          },
          tooltip: '전체 선택',
        ),
        if (_selectedPaths.isNotEmpty) ...[
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            onPressed: _createPdfFromSelected,
            tooltip: 'PDF로 만들기',
          ),
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
    String message;
    switch (_category) {
      case FileCategory.images:
        message = '스캔한 이미지가 없습니다';
        break;
      case FileCategory.pdfs:
        message = 'PDF 파일이 없습니다';
        break;
      case FileCategory.all:
        message = '스캔한 문서가 없습니다';
        break;
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.document_scanner_outlined, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(fontSize: 18, color: Colors.grey[600])),
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

  Widget _buildFileGrid(List<FileSystemEntity> scanFiles) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 0.65,
      ),
      itemCount: scanFiles.length,
      itemBuilder: (context, index) {
        final file = scanFiles[index] as File;
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
                } else if (!_selectedPaths.contains(file.path)) {
                  _selectedPaths.add(file.path);
                }
              });
            } else {
              if (isPdf) {
                _openPdfViewer(file);
              } else {
                _openImageViewer(file);
              }
            }
          },
          onLongPress: () {
            if (!_selectMode) {
              setState(() {
                _selectMode = true;
                if (!_selectedPaths.contains(file.path)) {
                  _selectedPaths.add(file.path);
                }
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
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.picture_as_pdf,
                                      size: 40, color: Colors.red[400]),
                                  const SizedBox(height: 4),
                                  Text('PDF',
                                      style: TextStyle(fontSize: 10, color: Colors.red[400])),
                                ],
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
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blue : Colors.black38,
                        shape: BoxShape.circle,
                      ),
                      child: isSelected
                          ? Center(
                              child: Text(
                                '${_selectedPaths.indexOf(file.path) + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            )
                          : const Icon(Icons.circle_outlined, color: Colors.white, size: 24),
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

  void _openPdfViewer(File file) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfViewerPage(pdfPath: file.path),
      ),
    ).then((_) => _loadScanFiles());
  }

  void _openPdfEditor(File file) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfEditPage(pdfPath: file.path),
      ),
    ).then((_) => _loadScanFiles());
  }

  Future<void> _renameFile(File file) async {
    final ext = path.extension(file.path);
    final currentName = path.basenameWithoutExtension(file.path);
    final controller = TextEditingController(text: currentName);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: AlertDialog(
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
      int failCount = 0;
      for (final f in files) {
        try {
          imageCache.evict(FileImage(f));
          await f.delete();
        } catch (e) {
          failCount++;
          debugPrint('파일 삭제 실패: ${f.path} - $e');
        }
      }
      imageCache.clear();
      _exitSelectMode();
      _loadScanFiles();
      if (failCount > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$failCount개 파일 삭제 실패')),
        );
      }
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

  Future<void> _createPdfFromSelected() async {
    final lowerPaths = _selectedPaths
        .where((p) {
          final lower = p.toLowerCase();
          return lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg');
        })
        .toList();

    debugPrint('PDF 변환 - 선택된 전체: ${_selectedPaths.length}개, 이미지만: ${lowerPaths.length}개');
    for (final p in _selectedPaths) {
      debugPrint('  선택 경로: $p');
    }

    final imagePaths = lowerPaths;

    if (imagePaths.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF로 변환할 이미지를 선택해주세요 (선택됨: ${_selectedPaths.length}개, 이미지: 0개)')),
        );
      }
      return;
    }

    final defaultName = 'scan_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}';
    final controller = TextEditingController(text: defaultName);

    final pdfTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: AlertDialog(
          title: const Text('PDF 만들기'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${imagePaths.length}개 이미지를 PDF로 변환합니다\n(선택 순서 = 페이지 순서)',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'PDF 파일 이름',
                  suffixText: '.pdf',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('만들기'),
            ),
          ],
        ),
      ),
    );

    if (pdfTitle == null || pdfTitle.isEmpty) return;

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }

    try {
      // 클릭 순서대로 PDF 페이지 생성 (먼저 클릭 = 1페이지)
      final scanner = DocumentScannerService.instance;
      final savedPath = await scanner.saveAsPdf(
        imagePaths: imagePaths,
        title: pdfTitle,
      );

      if (mounted) Navigator.pop(context);
      _exitSelectMode();
      _loadScanFiles();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF 저장 완료: ${path.basename(savedPath)}'),
            action: SnackBarAction(
              label: '공유',
              onPressed: () => Share.shareXFiles([XFile(savedPath)]),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 생성 실패: $e'), duration: const Duration(seconds: 8)),
        );
      }
    }
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
                  imageCache.clear();
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
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: AlertDialog(
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
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != currentName) {
      try {
        final dir = path.dirname(file.path);
        await file.rename('$dir${Platform.pathSeparator}$newName$ext');
        onRename();
      } catch (e) {
        debugPrint('이름 변경 실패: $e');
      }
    }
  }
}
