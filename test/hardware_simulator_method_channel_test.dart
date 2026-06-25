import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('performPenMove forwards contact state', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );

    await platform.performPenMove(
      0.2,
      0.8,
      true,
      0.0,
      45.0,
      20.0,
      3,
      isInContact: false,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'penMove');
    expect(calls.single.arguments, containsPair('isInContact', false));
  });
}
