import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hardware_simulator/hardware_simulator.dart';

void main() {
  runApp(const CursorVisibilityDemoApp());
}

class CursorVisibilityDemoApp extends StatelessWidget {
  const CursorVisibilityDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const CursorVisibilityDemoPage(),
    );
  }
}

enum _ViewerCursorState { waiting, locked, unlocked }

class CursorVisibilityDemoPage extends StatefulWidget {
  const CursorVisibilityDemoPage({super.key});

  @override
  State<CursorVisibilityDemoPage> createState() =>
      _CursorVisibilityDemoPageState();
}

class _CursorVisibilityDemoPageState extends State<CursorVisibilityDemoPage> {
  static const _callbackId = 49001;
  static const _maxEvents = 100;

  final List<String> _events = <String>[];
  _ViewerCursorState _state = _ViewerCursorState.waiting;
  int _textureUpdateCount = 0;

  @override
  void initState() {
    super.initState();
    HardwareSimulator.addCursorImageUpdated(
      _handleCursorMessage,
      _callbackId,
      true,
    );
  }

  @override
  void dispose() {
    HardwareSimulator.removeCursorImageUpdated(_callbackId);
    super.dispose();
  }

  void _handleCursorMessage(
    int message,
    int messageInfo,
    Uint8List cursorImage,
  ) {
    if (!mounted) return;

    switch (message) {
      case HardwareSimulator.CURSOR_INVISIBLE:
        _setCursorState(_ViewerCursorState.locked, 'LOCKED  cursor invisible');
      case HardwareSimulator.CURSOR_VISIBLE:
        final position = _decodePosition(cursorImage);
        final suffix = position == null
            ? ''
            : '  screen=$messageInfo x=${position.$1} y=${position.$2}';
        _setCursorState(
          _ViewerCursorState.unlocked,
          'UNLOCKED  cursor visible$suffix',
        );
      case HardwareSimulator.CURSOR_UPDATED_IMAGE:
        _recordTexture('bitmap hash=$messageInfo');
      case HardwareSimulator.CURSOR_UPDATED_DEFAULT:
        _recordTexture('system cursor id=$messageInfo');
      case HardwareSimulator.CURSOR_UPDATED_CACHED:
        _recordTexture('cached hash=$messageInfo');
    }
  }

  (String, String)? _decodePosition(Uint8List bytes) {
    if (bytes.length < 4) return null;
    final data = ByteData.sublistView(bytes);
    final x = data.getUint16(0, Endian.little) / 65535.0;
    final y = data.getUint16(2, Endian.little) / 65535.0;
    return (
      '${(x * 100).toStringAsFixed(1)}%',
      '${(y * 100).toStringAsFixed(1)}%',
    );
  }

  void _setCursorState(_ViewerCursorState state, String event) {
    setState(() {
      _state = state;
      _appendEvent(event);
    });
  }

  void _recordTexture(String detail) {
    setState(() {
      _textureUpdateCount++;
      _appendEvent('TEXTURE  $detail');
    });
  }

  void _appendEvent(String event) {
    final now = DateTime.now();
    final time = '${_twoDigits(now.hour)}:${_twoDigits(now.minute)}:'
        '${_twoDigits(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
    _events.insert(0, '$time  $event');
    if (_events.length > _maxEvents) {
      _events.removeRange(_maxEvents, _events.length);
    }
  }

  String _twoDigits(int value) => value.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (_state) {
      _ViewerCursorState.waiting => (
          'WAITING',
          Colors.blueGrey,
          Icons.hourglass_top
        ),
      _ViewerCursorState.locked => ('LOCKED', Colors.red, Icons.lock),
      _ViewerCursorState.unlocked => (
          'UNLOCKED',
          Colors.green,
          Icons.lock_open
        ),
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('macOS Host Cursor Visibility Monitor'),
        actions: [
          TextButton.icon(
            onPressed: () => setState(_events.clear),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                border: Border.all(color: color, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 22),
                child: Column(
                  children: [
                    Icon(icon, size: 46, color: color),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: color,
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                    const SizedBox(height: 4),
                    Text('Texture updates: $_textureUpdateCount'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '这个状态等价于 Viewer 的动态鼠标锁定状态。把窗口留在后台，'
              '依次测试输入文字、移动远程鼠标、B 站视频和游戏；观察事件顺序。',
            ),
            const SizedBox(height: 16),
            Text('Events', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _events.isEmpty
                    ? const Center(child: Text('Waiting for cursor events…'))
                    : SelectionArea(
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _events.length,
                          itemBuilder: (context, index) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              _events[index],
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
