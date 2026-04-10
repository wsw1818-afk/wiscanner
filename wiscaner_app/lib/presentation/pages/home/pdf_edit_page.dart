import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import '../../../core/services/document_scanner_service.dart';

/// PDF 편집 페이지 - 페이지 추가/삭제/순서변경/병합
class PdfEditPage extends StatefulWidget {
  final String pdfPath;

  const PdfEditPage({super.key, required this.pdfPath});

  @override
  State<PdfEditPage> createState() => _PdfEditPageState();
}

class _PdfEditPageState extends State<PdfEditPage> {
  final _scanner = DocumentScannerService.instance;
  bool _isProcessing = false;
  int _pageCount = 0;
  late List<int> _pageOrder; // 현재 페이지 순서

  @override
  void initState() {
    super.initState();
    _loadPdfInfo();
  }

  Future<void> _loadPdfInfo() async {
    setState(() => _isProcessing = true);
    try {
      final count = await _scanner.getPdfPageCount(widget.pdfPath);
      setState(() {
        _pageCount = count;
        _pageOrder = List.generate(count, (i) => i);
        _isProcessing = false;
      });
    } catch (e) {
      debugPrint('PDF 로드 실패: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 로드 실패: $e')),
        );
      }
    }
  }

  Future<void> _addPage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    setState(() => _isProcessing = true);
    try {
      await _scanner.addPageToPdf(
        pdfPath: widget.pdfPath,
        imagePath: picked.path,
      );
      await _loadPdfInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('페이지 추가 완료'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('페이지 추가 실패: $e')),
        );
      }
    }
  }

  Future<void> _deletePage(int index) async {
    if (_pageCount <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('마지막 페이지는 삭제할 수 없습니다')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('페이지 삭제'),
        content: Text('${index + 1}페이지를 삭제하시겠습니까?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isProcessing = true);
    try {
      await _scanner.removePageFromPdf(
        pdfPath: widget.pdfPath,
        pageIndex: _pageOrder[index],
      );
      await _loadPdfInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('페이지 삭제 완료'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('페이지 삭제 실패: $e')),
        );
      }
    }
  }

  Future<void> _applyReorder() async {
    bool changed = false;
    for (int i = 0; i < _pageOrder.length; i++) {
      if (_pageOrder[i] != i) {
        changed = true;
        break;
      }
    }
    if (!changed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('순서가 변경되지 않았습니다')),
      );
      return;
    }

    setState(() => _isProcessing = true);
    try {
      await _scanner.reorderPdfPages(
        pdfPath: widget.pdfPath,
        newOrder: _pageOrder,
      );
      await _loadPdfInfo();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('순서 변경 완료'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('순서 변경 실패: $e')),
        );
      }
    }
  }

  Future<void> _mergePdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (result == null ||
        result.files.isEmpty ||
        result.files.first.path == null) return;

    final controller = TextEditingController(
      text: 'merged_${path.basenameWithoutExtension(widget.pdfPath)}',
    );

    final outputTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('PDF 병합'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: '병합 파일 이름',
            suffixText: '.pdf',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('병합'),
          ),
        ],
      ),
    );

    if (outputTitle == null || outputTitle.isEmpty) return;

    setState(() => _isProcessing = true);
    try {
      final mergedPath = await _scanner.mergePdfs(
        pdf1Path: widget.pdfPath,
        pdf2Path: result.files.first.path!,
        outputTitle: outputTitle,
      );
      if (mergedPath != null && mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('병합 완료: ${path.basename(mergedPath)}'),
            backgroundColor: Colors.green,
            action: SnackBarAction(
              label: '공유',
              onPressed: () => Share.shareXFiles([XFile(mergedPath)]),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 병합 실패: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = path.basenameWithoutExtension(widget.pdfPath);

    return Scaffold(
      appBar: AppBar(
        title: Text(fileName, style: const TextStyle(fontSize: 14)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_photo_alternate),
            onPressed: _isProcessing ? null : _addPage,
            tooltip: '페이지 추가',
          ),
          IconButton(
            icon: const Icon(Icons.merge),
            onPressed: _isProcessing ? null : _mergePdf,
            tooltip: 'PDF 병합',
          ),
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _isProcessing ? null : _applyReorder,
            tooltip: '순서 저장',
          ),
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => Share.shareXFiles([XFile(widget.pdfPath)]),
            tooltip: '공유',
          ),
        ],
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : _pageCount == 0
              ? const Center(child: Text('페이지가 없습니다'))
              : ReorderableListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _pageOrder.length,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      if (newIndex > oldIndex) newIndex--;
                      final item = _pageOrder.removeAt(oldIndex);
                      _pageOrder.insert(newIndex, item);
                    });
                  },
                  itemBuilder: (context, index) {
                    final originalPage = _pageOrder[index];
                    return _PageThumbnailCard(
                      key: ValueKey('page_$originalPage'),
                      pdfPath: widget.pdfPath,
                      pageNumber: originalPage + 1, // 1-based
                      currentPosition: index + 1,
                      totalPages: _pageOrder.length,
                      onDelete: () => _deletePage(index),
                    );
                  },
                ),
    );
  }
}

/// 개별 페이지 썸네일 카드
class _PageThumbnailCard extends StatelessWidget {
  final String pdfPath;
  final int pageNumber;     // 원본 페이지 번호 (1-based)
  final int currentPosition; // 현재 순서 위치
  final int totalPages;
  final VoidCallback onDelete;

  const _PageThumbnailCard({
    super.key,
    required this.pdfPath,
    required this.pageNumber,
    required this.currentPosition,
    required this.totalPages,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            // 페이지 썸네일 (SfPdfViewer 단일 페이지)
            Container(
              width: 90,
              height: 120,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: IgnorePointer(
                  child: SfPdfViewer.file(
                    File(pdfPath),
                    initialPageNumber: pageNumber,
                    canShowScrollHead: false,
                    canShowScrollStatus: false,
                    canShowPaginationDialog: false,
                    pageLayoutMode: PdfPageLayoutMode.single,
                    enableDoubleTapZooming: false,
                    enableTextSelection: false,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 페이지 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '페이지 $pageNumber',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$currentPosition / $totalPages 번째',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  // 삭제 버튼
                  OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline,
                        size: 16, color: Colors.red),
                    label: const Text('삭제',
                        style: TextStyle(fontSize: 12, color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            // 드래그 핸들
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.drag_handle, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
