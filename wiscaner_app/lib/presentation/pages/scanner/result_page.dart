import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as path;
import '../../../core/services/document_scanner_service.dart';
import '../../../core/services/dual_page_detector_service.dart';

/// 스캔 결과 확인 + 저장/공유/PDF 페이지
class ResultPage extends StatefulWidget {
  final List<String> imagePaths;

  const ResultPage({
    super.key,
    required this.imagePaths,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  final _scanner = DocumentScannerService.instance;
  bool _isProcessing = false;
  int _currentIndex = 0;
  ScanFilter _selectedFilter = ScanFilter.original;
  final Map<String, String> _filteredPaths = {};

  // 양면 분리
  bool _dualDetected = false;
  DualPageSplitResult? _splitResult;
  late List<String> _displayPaths;

  String get _currentImagePath {
    final key = '${_displayPaths[_currentIndex]}_${_selectedFilter.name}';
    return _filteredPaths[key] ?? _displayPaths[_currentIndex];
  }

  @override
  void initState() {
    super.initState();
    _displayPaths = List.from(widget.imagePaths);
    _checkDualPage();
  }

  /// 스캔 모드(ScannerPage)로 복귀 — ResultPage + CropPage를 pop
  void _returnToScanner() {
    // ResultPage → CropPage → ScannerPage: 2단계 pop
    int popCount = 0;
    Navigator.of(context).popUntil((route) {
      // ScannerPage에 도달하거나 첫 화면이면 멈춤
      if (route.isFirst) return true;
      popCount++;
      return popCount > 2; // ResultPage(1) + CropPage(2) pop
    });
  }

  /// 양면 펼침 자동 감지
  Future<void> _checkDualPage() async {
    try {
      final imageBytes = await File(widget.imagePaths.first).readAsBytes();
      final result = await DualPageDetectorService.instance.detect(imageBytes);
      if (mounted && result != null && result.pageCount == 2 && result.confidence > 0.7) {
        setState(() => _dualDetected = true);
        debugPrint('[양면감지] 양면 페이지 감지됨 (conf=${result.confidence.toStringAsFixed(2)})');
      }
    } catch (e) {
      debugPrint('[양면감지] 오류: $e');
    }
  }

  /// 양면 분리 실행
  Future<void> _splitDualPages() async {
    setState(() => _isProcessing = true);
    try {
      final result = await _scanner.detectAndSplitDualPage(widget.imagePaths.first);
      if (mounted && result.pageCount == 2) {
        setState(() {
          _splitResult = result;
          _displayPaths = result.paths;
          _currentIndex = 0;
          _filteredPaths.clear();
          _isProcessing = false;
        });
      } else {
        if (mounted) setState(() => _isProcessing = false);
      }
    } catch (e) {
      debugPrint('[양면분리] 실패: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('양면 분리 실패: $e')),
        );
      }
    }
  }

  /// 분리 취소 → 원본으로 복원
  void _undoSplit() {
    setState(() {
      _splitResult = null;
      _displayPaths = List.from(widget.imagePaths);
      _currentIndex = 0;
      _filteredPaths.clear();
    });
  }

  // ─── 이미지 회전 ───
  Future<void> _rotateImage() async {
    setState(() => _isProcessing = true);
    try {
      final result = await _scanner.rotateImage(_currentImagePath, 90);
      if (result != null && mounted) {
        setState(() {
          _displayPaths[_currentIndex] = result;
          // 필터 캐시 초기화 (회전된 이미지이므로)
          _filteredPaths.removeWhere((key, _) =>
              key.startsWith(_displayPaths[_currentIndex]));
          _selectedFilter = ScanFilter.original;
        });
      }
    } catch (e) {
      debugPrint('회전 실패: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        foregroundColor: Colors.white,
        title: Text(_displayPaths.length > 1
            ? '스캔 결과 (${_currentIndex + 1}/${_displayPaths.length})'
            : '스캔 결과'),
        actions: [
          if (_displayPaths.length > 1) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back_ios, size: 18),
              onPressed: _currentIndex > 0
                  ? () => setState(() => _currentIndex--)
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios, size: 18),
              onPressed: _currentIndex < _displayPaths.length - 1
                  ? () => setState(() => _currentIndex++)
                  : null,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // 이미지 미리보기
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Image.file(
                      File(_currentImagePath),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                if (_isProcessing)
                  Container(
                    color: Colors.black38,
                    child: const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),

          // 양면 감지 배너
          if (_dualDetected && _splitResult == null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFF1565C0),
              child: Row(
                children: [
                  const Icon(Icons.auto_stories, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '양면 펼침이 감지되었습니다',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: _isProcessing ? null : _splitDualPages,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: Colors.white24,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('분리하기', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),

          // 분리 완료 배너
          if (_splitResult != null && _splitResult!.pageCount == 2)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: const Color(0xFF2E7D32),
              child: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_splitResult!.pageCount}페이지로 분리 완료',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: _undoSplit,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('원본으로', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),

          // 필터 + 회전 바
          _buildFilterAndRotateBar(),

          // 액션 버튼들
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SafeArea(
              child: Column(
                children: [
                  // 이미지로 저장
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isProcessing ? null : _saveAsImage,
                      icon: const Icon(Icons.save_alt, size: 22),
                      label: Text(
                        _displayPaths.length > 1
                            ? '이미지로 저장 (${_displayPaths.length}장)'
                            : '이미지로 저장',
                        style: const TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      // PDF로 저장
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isProcessing ? null : _saveAsPdf,
                          icon: const Icon(Icons.picture_as_pdf, size: 18),
                          label: Text(
                            _displayPaths.length > 1
                                ? 'PDF (${_displayPaths.length}장)'
                                : 'PDF로 저장',
                            style: const TextStyle(fontSize: 13),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 공유
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isProcessing ? null : _shareImage,
                          icon: const Icon(Icons.share, size: 18),
                          label: const Text('공유', style: TextStyle(fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterAndRotateBar() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 16),
              children: [
                _buildFilterChip('원본', ScanFilter.original, Icons.image),
                const SizedBox(width: 6),
                _buildFilterChip('문서', ScanFilter.document, Icons.description),
              ],
            ),
          ),
          // 회전 버튼
          Container(
            margin: const EdgeInsets.only(right: 8),
            child: IconButton(
              icon: const Icon(Icons.rotate_right, color: Colors.white70),
              onPressed: _isProcessing ? null : _rotateImage,
              tooltip: '90° 회전',
              style: IconButton.styleFrom(
                backgroundColor: Colors.white10,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, ScanFilter filter, [IconData? icon]) {
    final isSelected = _selectedFilter == filter;
    return GestureDetector(
      onTap: () => _applyFilter(filter),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: isSelected ? Colors.white : Colors.white70),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? Colors.white : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyFilter(ScanFilter filter) async {
    if (filter == _selectedFilter) return;

    final originalPath = _displayPaths[_currentIndex];
    final key = '${originalPath}_${filter.name}';

    if (_filteredPaths.containsKey(key)) {
      setState(() => _selectedFilter = filter);
      return;
    }

    if (filter == ScanFilter.original) {
      setState(() => _selectedFilter = filter);
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final result = await _scanner.applyFilter(
        imagePath: originalPath,
        filter: filter,
      );
      if (result != null && mounted) {
        _filteredPaths[key] = result;
        setState(() => _selectedFilter = filter);
      }
    } catch (e) {
      debugPrint('필터 적용 실패: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _saveAsImage() async {
    setState(() => _isProcessing = true);
    try {
      final timestamp = DateTime.now();
      final baseName = 'scan_${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}${timestamp.day.toString().padLeft(2, '0')}_${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}';

      if (_splitResult != null && _displayPaths.length > 1) {
        final savedPaths = <String>[];
        for (int i = 0; i < _displayPaths.length; i++) {
          final key = '${_displayPaths[i]}_${_selectedFilter.name}';
          final imgPath = _filteredPaths[key] ?? _displayPaths[i];
          final fileName = '${baseName}_p${i + 1}';
          final saved = await _scanner.saveAsImage(imagePath: imgPath, fileName: fileName);
          if (saved != null) savedPaths.add(saved);
        }
        if (mounted && savedPaths.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${savedPaths.length}장 저장 완료'),
              backgroundColor: Colors.green[700],
            ),
          );
          _returnToScanner();
        }
      } else {
        final savedPath = await _scanner.saveAsImage(
          imagePath: _currentImagePath,
          fileName: baseName,
        );
        if (savedPath != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('저장 완료: ${path.basename(savedPath)}'),
              backgroundColor: Colors.green[700],
            ),
          );
          _returnToScanner();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _saveAsPdf() async {
    setState(() => _isProcessing = true);
    try {
      final imagePaths = <String>[];
      for (int i = 0; i < _displayPaths.length; i++) {
        final key = '${_displayPaths[i]}_${_selectedFilter.name}';
        imagePaths.add(_filteredPaths[key] ?? _displayPaths[i]);
      }

      final timestamp = DateTime.now();
      final title = 'scan_${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}${timestamp.day.toString().padLeft(2, '0')}_${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}';

      final savedPath = await _scanner.saveAsPdf(
        imagePaths: imagePaths,
        title: title,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('PDF 저장 완료: ${path.basename(savedPath)}'),
            backgroundColor: Colors.green[700],
          ),
        );
        _returnToScanner();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('PDF 저장 실패: $e'), duration: const Duration(seconds: 8)),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _shareImage() async {
    try {
      if (_splitResult != null && _displayPaths.length > 1) {
        await Share.shareXFiles(_displayPaths.map((p) => XFile(p)).toList());
      } else {
        await Share.shareXFiles([XFile(_currentImagePath)]);
      }
      if (mounted) _returnToScanner();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('공유 실패: $e')),
        );
      }
    }
  }
}
