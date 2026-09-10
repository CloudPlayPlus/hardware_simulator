import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_simulator/hardware_simulator.dart';
import 'package:hardware_simulator/hardware_simulator_method_channel.dart';
import 'package:hardware_simulator/hardware_simulator_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final throwsError in [true, false]) {
    test(
        'failed disposal ($throwsError) can be retried and successful disposal is idempotent',
        () async {
      final previousPlatform = HardwareSimulatorPlatform.instance;
      HardwareSimulatorPlatform.instance = MethodChannelHardwareSimulator();
      addTearDown(() => HardwareSimulatorPlatform.instance = previousPlatform);
      const channel = MethodChannel('hardware_simulator');
      var attempts = 0;
      final release = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'removeGameController' && ++attempts == 1) {
          await release.future;
          if (throwsError) throw PlatformException(code: 'temporary_failure');
          return 0; // Windows returns the boolean removal result as an integer.
        }
        return 1;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final controller = GameController(1);
      final first = controller.dispose();
      final concurrent = controller.dispose();
      expect(identical(first, concurrent), isTrue);
      final firstFailure =
          expectLater(first, throwsA(isA<PlatformException>()));
      final concurrentFailure =
          expectLater(concurrent, throwsA(isA<PlatformException>()));
      await pumpEventQueue();
      expect(attempts, 1);
      release.complete();
      await Future.wait([firstFailure, concurrentFailure]);
      await controller.dispose();
      await controller.dispose();
      expect(attempts, 2);
    });
  }
  test('late feedback cannot reach a replacement controller in the same slot',
      () async {
    final previousPlatform = HardwareSimulatorPlatform.instance;
    HardwareSimulatorPlatform.instance = MethodChannelHardwareSimulator();
    addTearDown(() => HardwareSimulatorPlatform.instance = previousPlatform);
    const channel = MethodChannel('hardware_simulator');
    final tokens = <int>[];
    final actions = <Object?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'subscribeGamepadRumble') {
        tokens.add((call.arguments as Map)['token'] as int);
      }
      if (call.method == 'removeGameController') return 1;
      if (call.method == 'doControlAction') actions.add(call.arguments);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final first = GameController(1);
    await first.enableRumbleFeedback();
    await first.dispose();
    await expectLater(first.simulate('0 0 0 0 0 0 0'), throwsStateError);
    final replacement = GameController(1);
    await replacement.enableRumbleFeedback();
    await expectLater(first.enableRumbleFeedback(), throwsStateError);
    await expectLater(first.simulate('4096 0 0 0 0 0 0'), throwsStateError);
    expect(actions, isEmpty);
    await replacement.simulate('0 0 0 0 0 0 0');
    expect(actions, [
      {'id': 1, 'action': '0 0 0 0 0 0 0'}
    ]);
    expect(tokens, hasLength(2));
    expect(tokens[0], isNot(tokens[1]));
    final events = <GamepadRumbleEvent>[];
    final subscription = replacement.rumbleEvents.listen(events.add);
    addTearDown(subscription.cancel);
    for (final (nativeId, token) in [
      (1, tokens[0]),
      (1, tokens[1]),
      (2, tokens[1])
    ]) {
      final done = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        'hardware_simulator',
        const StandardMethodCodec().encodeMethodCall(MethodCall(
            'onGamepadRumble',
            {'id': nativeId, 'token': token, 'low': 65535, 'high': 0})),
        (_) => done.complete(),
      );
      await done.future;
    }
    expect(events.length, 1);
    expect(events.single.controllerId, 1);
    expect(events.single.lowFrequency, 65535);
    expect(events.single.highFrequency, 0);
    await replacement.dispose();
  });
}
