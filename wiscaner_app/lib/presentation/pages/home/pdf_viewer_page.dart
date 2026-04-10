import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as path;
import 'pdf_edit_page.dart';

/// PDF 뷰어 페이지 - 앱에서 만든 PDF를 직접 열람
class PdfViewerPage extends StatefulWidget {
  final String pdfPath;
  const PdfViewerPage({super.key, required this.pdfPath});

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  final PdfViewerController _controller = PdfViewerController();
  int _totalPages = 0;
  int _currentPage = 1;

  String get _fileName => path.basenameWithoutExtension(widget.pdfPath);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _sharePdf() {
    Share.shareXFiles([XFile(widget.pdfPath)], text: _fileName);
  }

  void _openEditor() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PdfEditPage(pdfPath: widget.pdfPath),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName, style: const TextStyle(fontSize: 14)),
        actions: [
          // 페이지 표시
          if (_totalPages > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '$_currentPage / $_totalPages',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            ),
          // 편집 (순서 변경/추가/삭제)
          IconButton(
            icon: const Icon(Icons.edit_note),
            onPressed: _openEditor,
            tooltip: '편집',
          ),
          // 공유
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _sharePdf,
            tooltip: '공유',
          ),
        ],
      ),
      body: SfPdfViewer.file(
        File(widget.pdfPath),
        controller: _controller,
        onDocumentLoaded: (details) {
          setState(() {
            _totalPages = details.document.pages.count;
          });
        },
        onPageChanged: (details) {
          setState(() {
            _currentPage = details.newPageNumber;
          });
        },
      ),
    );
  }
}
