import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_simulator/hardware_simulator.dart';
import 'package:hardware_simulator/hardware_simulator_method_channel.dart';
import 'package:hardware_simulator/hardware_simulator_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('failed disposal can be retried and successful disposal is idempotent',
      () async {
    final previousPlatform = HardwareSimulatorPlatform.instance;
    HardwareSimulatorPlatform.instance = MethodChannelHardwareSimulator();
    addTearDown(() => HardwareSimulatorPlatform.instance = previousPlatform);
    const channel = MethodChannel('hardware_simulator');
    var attempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'removeGameController' && ++attempts == 1) {
        throw PlatformException(code: 'temporary_failure');
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final controller = GameController(1);
    await expectLater(controller.dispose(), throwsA(isA<PlatformException>()));
    await controller.dispose();
    await controller.dispose();
    expect(attempts, 2);
  });
  test('late feedback cannot reach a replacement controller in the same slot',
      () async {
    final previousPlatform = HardwareSimulatorPlatform.instance;
    HardwareSimulatorPlatform.instance = MethodChannelHardwareSimulator();
    addTearDown(() => HardwareSimulatorPlatform.instance = previousPlatform);
    const channel = MethodChannel('hardware_simulator');
    final tokens = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'subscribeGamepadRumble') {
        tokens.add((call.arguments as Map)['token'] as int);
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final first = GameController(1);
    await first.enableRumbleFeedback();
    await first.dispose();
    final replacement = GameController(1);
    await replacement.enableRumbleFeedback();
    expect(tokens[0], isNot(tokens[1]));
    final events = <GamepadRumbleEvent>[];
    final subscription = replacement.rumbleEvents.listen(events.add);
    addTearDown(subscription.cancel);
    for (final token in tokens) {
      final done = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'hardware_simulator',
        const StandardMethodCodec().encodeMethodCall(MethodCall(
            'onGamepadRumble', {'token': token, 'low': 65535, 'high': 0})),
        (_) => done.complete(),
      );
      await done.future;
    }
    expect(events.length, 1);
    expect(events.single.lowFrequency, 65535);
    expect(events.single.highFrequency, 0);
    await replacement.dispose();
  });
}
