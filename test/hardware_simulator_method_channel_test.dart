import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_simulator/hardware_simulator.dart';
import 'package:hardware_simulator/hardware_simulator_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelHardwareSimulator platform = MethodChannelHardwareSimulator();
  const MethodChannel channel = MethodChannel('hardware_simulator');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform.getPlatformVersion(), '42');
  });

  test('performPenHover sends penHover method call', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );

    await platform.performPenHover(0.25, 0.75, 2);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'penHover');
    expect(calls.single.arguments, {
      'x': 0.25,
      'y': 0.75,
      'screenId': 2,
    });
  });

  test('unlockCursorAndReseed sends normalized window position', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );

    await platform.unlockCursorAndReseed(0.25, 0.75);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'unlockCursorAndReseed');
    expect(calls.single.arguments, {'x': 0.25, 'y': 0.75});
  });

  test('unlockCursorAndReseed does not call channel while unlocked', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );
    HardwareSimulator.cursorlocked = false;

    await HardwareSimulator.unlockCursorAndReseed(0.25, 0.75);

    expect(calls, isEmpty);
  });
}
