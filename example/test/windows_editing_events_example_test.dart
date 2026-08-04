import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_simulator_example/windows_editing_events_example.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('hardware_simulator');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('直接展示原生检查给出的键盘弹出或收起结论', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WindowsEditingEventsExample()),
    );
    await tester.pump();
    expect(find.text('等待远端点击'), findsOneWidget);

    await _sendDecision(
      const <String, dynamic>{
        'active': true,
        'secure': false,
      },
    );
    await tester.pump();
    expect(find.text('弹出原生键盘'), findsOneWidget);
    expect(find.text('检测到普通可编辑文本控件'), findsOneWidget);
    expect(find.text('普通文本输入'), findsOneWidget);

    await _sendDecision(
      const <String, dynamic>{
        'active': false,
        'secure': null,
      },
    );
    await tester.pump();
    expect(find.text('收起原生键盘'), findsOneWidget);
    expect(find.text('未检测到可编辑文本控件'), findsOneWidget);
    expect(find.text('2 次检查 · 2 次决策变化'), findsOneWidget);
  });
}

Future<void> _sendDecision(Map<String, dynamic> decision) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'hardware_simulator',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('onWindowsTextInputDecision', decision),
    ),
    null,
  );
}
