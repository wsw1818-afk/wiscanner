import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SharedPreferences _prefs;
  bool _loaded = false;

  // 설정값
  String _saveFormat = 'png';
  bool _autoScan = true;
  bool _tapToCapture = false;
  String _storageInfo = '';
  bool _cameraGranted = false;
  bool _micGranted = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _prefs = await SharedPreferences.getInstance();
    final cameraStatus = await Permission.camera.status;
    final micStatus = await Permission.microphone.status;

    String storageInfo = '';
    try {
      if (Platform.isAndroid) {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final parts = extDir.path.split('Android');
          final scanDir = Directory('${parts[0]}Pictures${Platform.pathSeparator}WiScanner');
          if (await scanDir.exists()) {
            final files = await scanDir.list().toList();
            int totalSize = 0;
            for (final f in files) {
              if (f is File) totalSize += await f.length();
            }
            storageInfo = '${files.length}개 파일, ${_formatBytes(totalSize)}';
          } else {
            storageInfo = '파일 없음';
          }
        }
      }
    } catch (_) {
      storageInfo = '확인 불가';
    }

    if (mounted) {
      setState(() {
        _saveFormat = _prefs.getString('saveFormat') ?? 'png';
        _autoScan = _prefs.getBool('autoScan') ?? true;
        _tapToCapture = _prefs.getBool('tapToCapture') ?? false;
        _cameraGranted = cameraStatus.isGranted;
        _micGranted = micStatus.isGranted;
        _storageInfo = storageInfo;
        _loaded = true;
      });
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(
        appBar: AppBar(title: const Text('설정')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: ListView(
        children: [
          // ── 스캔 설정 ──
          _buildSectionHeader('스캔 설정'),
          SwitchListTile(
            title: const Text('자동 스캔'),
            subtitle: const Text('문서 감지 시 자동으로 촬영'),
            value: _autoScan,
            onChanged: (v) {
              setState(() => _autoScan = v);
              _prefs.setBool('autoScan', v);
            },
            secondary: const Icon(Icons.auto_awesome),
          ),
          SwitchListTile(
            title: const Text('터치 촬영'),
            subtitle: const Text('화면 아무 곳이나 터치하면 즉시 촬영'),
            value: _tapToCapture,
            onChanged: (v) {
              setState(() => _tapToCapture = v);
              _prefs.setBool('tapToCapture', v);
            },
            secondary: const Icon(Icons.touch_app),
          ),

          // ── 저장 설정 ──
          _buildSectionHeader('저장 설정'),
          ListTile(
            leading: const Icon(Icons.image),
            title: const Text('저장 형식'),
            subtitle: Text(_saveFormat.toUpperCase()),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showFormatPicker(),
          ),
          const ListTile(
            leading: Icon(Icons.high_quality, color: Colors.green),
            title: Text('이미지 품질'),
            subtitle: Text('항상 최고 품질 (100%)'),
            trailing: Icon(Icons.check_circle, color: Colors.green),
          ),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('저장 위치'),
            subtitle: const Text('Pictures/WiScanner'),
            trailing: Text(_storageInfo, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ),

          // ── 권한 상태 ──
          _buildSectionHeader('권한'),
          ListTile(
            leading: Icon(Icons.camera_alt, color: _cameraGranted ? Colors.green : Colors.red),
            title: const Text('카메라'),
            subtitle: Text(_cameraGranted ? '허용됨' : '거부됨'),
            trailing: _cameraGranted
                ? const Icon(Icons.check_circle, color: Colors.green)
                : TextButton(
                    onPressed: () => openAppSettings(),
                    child: const Text('설정'),
                  ),
          ),
          ListTile(
            leading: Icon(Icons.mic, color: _micGranted ? Colors.green : Colors.red),
            title: const Text('마이크 (음성 명령)'),
            subtitle: Text(_micGranted ? '허용됨' : '거부됨'),
            trailing: _micGranted
                ? const Icon(Icons.check_circle, color: Colors.green)
                : TextButton(
                    onPressed: () => openAppSettings(),
                    child: const Text('설정'),
                  ),
          ),

          // ── 앱 정보 ──
          _buildSectionHeader('앱 정보'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('WiScanner'),
            subtitle: Text('버전 1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('오픈소스 라이선스'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'WiScanner',
              applicationVersion: '1.0.0',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  void _showFormatPicker() {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('저장 형식'),
        children: [
          for (final fmt in ['png', 'jpg'])
            SimpleDialogOption(
              onPressed: () {
                setState(() => _saveFormat = fmt);
                _prefs.setString('saveFormat', fmt);
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  Radio<String>(
                    value: fmt,
                    groupValue: _saveFormat,
                    onChanged: (_) {},
                  ),
                  Text(fmt.toUpperCase()),
                  if (fmt == 'png') const Text('  (고화질, 큰 파일)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  if (fmt == 'jpg') const Text('  (압축, 작은 파일)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
