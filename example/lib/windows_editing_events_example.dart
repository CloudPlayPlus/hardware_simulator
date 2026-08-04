import 'package:flutter/material.dart';
import 'package:hardware_simulator/hardware_simulator.dart';

class WindowsEditingEventsExample extends StatefulWidget {
  const WindowsEditingEventsExample({super.key});

  @override
  State<WindowsEditingEventsExample> createState() =>
      _WindowsEditingEventsExampleState();
}

class _WindowsEditingEventsExampleState
    extends State<WindowsEditingEventsExample> {
  final HWMouse _testMouse = HWMouse();
  bool _listening = false;
  bool _injectingTestClick = false;
  bool? _showKeyboard;
  WindowsTextInputDecision? _lastDecision;
  int _inspectionCount = 0;
  int _decisionChangeCount = 0;

  @override
  void initState() {
    super.initState();
    _startListening();
  }

  @override
  void dispose() {
    if (_listening) {
      HardwareSimulator.removeWindowsTextInputDecision(_onDecision);
    }
    super.dispose();
  }

  void _startListening() {
    if (_listening) return;
    HardwareSimulator.addWindowsTextInputDecision(_onDecision);
    setState(() => _listening = true);
  }

  void _stopListening() {
    if (!_listening) return;
    HardwareSimulator.removeWindowsTextInputDecision(_onDecision);
    setState(() => _listening = false);
  }

  void _resetDecision() {
    setState(() {
      _showKeyboard = null;
      _lastDecision = null;
      _inspectionCount = 0;
      _decisionChangeCount = 0;
    });
  }

  void _onDecision(WindowsTextInputDecision decision) {
    if (!mounted) return;
    setState(() {
      _inspectionCount++;
      if (_showKeyboard != decision.active) {
        _decisionChangeCount++;
      }
      _showKeyboard = decision.active;
      _lastDecision = decision;
    });
  }

  Future<void> _injectTestClick() async {
    if (_injectingTestClick) return;
    setState(() => _injectingTestClick = true);
    try {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (!mounted || !_listening) return;
      _testMouse.performMouseClick(1, true);
      _testMouse.performMouseClick(1, false);
    } finally {
      if (mounted) {
        setState(() => _injectingTestClick = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Windows 键盘弹出决策')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '这里不监听全局焦点或鼠标事件。仅在插件注入远端左键抬起后，'
              '原生线程等待 80ms，再做一次 UI Automation 检查；页面只展示'
              '最终的弹出或收起结论。可启动 3 秒测试点击，再把鼠标移到其它'
              '应用的文本框或非文本区域。',
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _listening ? null : _startListening,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('开始检查'),
                ),
                OutlinedButton.icon(
                  onPressed: _listening ? _stopListening : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('停止检查'),
                ),
                OutlinedButton.icon(
                  onPressed: _listening && !_injectingTestClick
                      ? _injectTestClick
                      : null,
                  icon: const Icon(Icons.ads_click),
                  label: Text(
                    _injectingTestClick ? '请把鼠标移到目标控件…' : '3 秒后模拟远端点击',
                  ),
                ),
                TextButton.icon(
                  onPressed: _resetDecision,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('重置判断'),
                ),
                Chip(
                  avatar: Icon(
                    _listening ? Icons.sensors : Icons.sensors_off,
                    size: 18,
                  ),
                  label: Text(_listening ? '按需检查已启用' : '检查已停止'),
                ),
                Text('$_inspectionCount 次检查 · $_decisionChangeCount 次决策变化'),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _DecisionPanel(
                showKeyboard: _showKeyboard,
                decision: _lastDecision,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecisionPanel extends StatelessWidget {
  const _DecisionPanel({
    required this.showKeyboard,
    required this.decision,
  });

  final bool? showKeyboard;
  final WindowsTextInputDecision? decision;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (showKeyboard) {
      true => Colors.green,
      false => scheme.outline,
      null => scheme.primary,
    };
    final icon = switch (showKeyboard) {
      true => Icons.keyboard_alt,
      false => Icons.keyboard_hide,
      null => Icons.touch_app,
    };
    final title = switch (showKeyboard) {
      true => '弹出原生键盘',
      false => '收起原生键盘',
      null => '等待远端点击',
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 88, color: color),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 16),
              Text(
                decision == null
                    ? '点击远端应用中的文本框或非文本区域进行验证'
                    : _description(decision!),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (decision?.active == true) ...[
                const SizedBox(height: 20),
                Chip(
                  avatar: Icon(
                    decision!.secure == true
                        ? Icons.password
                        : Icons.text_fields,
                    size: 18,
                  ),
                  label: Text(_secureLabel(decision!.secure)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _description(WindowsTextInputDecision decision) {
    return switch ((decision.active, decision.secure)) {
      (true, true) => '检测到密码输入控件；不读取任何文本内容',
      (true, false) => '检测到普通可编辑文本控件',
      (true, null) => '检测到可编辑文本控件；密码状态未知',
      (false, _) => '未检测到可编辑文本控件',
    };
  }

  static String _secureLabel(bool? secure) {
    return switch (secure) {
      true => '密码输入',
      false => '普通文本输入',
      null => '密码状态未知',
    };
  }
}
