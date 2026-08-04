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

  test('performTrackpadScroll preserves fractional deltas', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );

    await platform.performTrackpadScroll(
      0.125,
      -0.375,
      phase: TrackpadScrollPhase.changed,
      isMomentum: true,
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'trackpadScroll');
    expect(calls.single.arguments, {
      'dx': 0.125,
      'dy': -0.375,
      'phase': 'changed',
      'isMomentum': true,
    });
  });

  test('performTrackpadScroll falls back when native method is missing',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        if (methodCall.method == 'trackpadScroll') {
          throw MissingPluginException();
        }
        return null;
      },
    );

    await platform.performTrackpadScroll(0.125, -0.375);

    expect(calls.map((call) => call.method), [
      'trackpadScroll',
      'mouseScroll',
    ]);
    expect(calls.last.arguments, {
      'dx': 0.125,
      'dy': -0.375,
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

  test('first and last trackpad listeners manage native capture', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return methodCall.method == 'startTrackpadScrollCapture';
      },
    );

    void firstListener(TrackpadScrollEvent _) {}
    void secondListener(TrackpadScrollEvent _) {}
    platform.addTrackpadScroll(firstListener);
    platform.addTrackpadScroll(firstListener);
    platform.addTrackpadScroll(secondListener);
    await Future<void>.delayed(Duration.zero);
    platform.removeTrackpadScroll(firstListener);
    await Future<void>.delayed(Duration.zero);
    expect(calls.map((call) => call.method), ['startTrackpadScrollCapture']);

    platform.removeTrackpadScroll(secondListener);
    await Future<void>.delayed(Duration.zero);

    expect(
      calls.map((call) => call.method),
      ['startTrackpadScrollCapture', 'stopTrackpadScrollCapture'],
    );
  });

  test('decodes native trackpad scroll events', () async {
    TrackpadScrollEvent? received;
    late TrackpadScrollCallback listener;
    listener = (event) {
      received = event;
      platform.removeTrackpadScroll(listener);
    };
    platform.addTrackpadScroll(listener);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'hardware_simulator',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onTrackpadScroll', <String, dynamic>{
          'x': 125,
          'y': 250.5,
          'dx': 1.25,
          'dy': -4,
          'phase': 'changed',
          'isMomentum': true,
        }),
      ),
      null,
    );

    expect(received, isNotNull);
    expect(received!.x, 125);
    expect(received!.y, 250.5);
    expect(received!.deltaX, 1.25);
    expect(received!.deltaY, -4);
    expect(received!.phase, TrackpadScrollPhase.changed);
    expect(received!.isMomentum, isTrue);
    await Future<void>.delayed(Duration.zero);
  });

  test('first and last Windows text input listeners manage native capture',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return methodCall.method == 'startWindowsTextInputDecisionCapture';
      },
    );

    void firstListener(WindowsTextInputDecision _) {}
    void secondListener(WindowsTextInputDecision _) {}
    platform.addWindowsTextInputDecision(firstListener);
    platform.addWindowsTextInputDecision(firstListener);
    platform.addWindowsTextInputDecision(secondListener);
    await Future<void>.delayed(Duration.zero);

    platform.removeWindowsTextInputDecision(firstListener);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls.map((call) => call.method),
      ['startWindowsTextInputDecisionCapture'],
    );

    platform.removeWindowsTextInputDecision(secondListener);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls.map((call) => call.method),
      [
        'startWindowsTextInputDecisionCapture',
        'stopWindowsTextInputDecisionCapture',
      ],
    );
  });

  test('decodes minimal Windows text input decisions', () async {
    WindowsTextInputDecision? received;
    late WindowsTextInputDecisionCallback listener;
    listener = (decision) {
      received = decision;
      platform.removeWindowsTextInputDecision(listener);
    };
    platform.addWindowsTextInputDecision(listener);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'hardware_simulator',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onWindowsTextInputDecision', <String, dynamic>{
          'active': true,
          'secure': false,
        }),
      ),
      null,
    );

    expect(received, isNotNull);
    expect(received!.active, isTrue);
    expect(received!.secure, isFalse);
    await Future<void>.delayed(Duration.zero);
  });

  test('normalizes unknown and inactive secure state to null', () {
    expect(
      WindowsTextInputDecision.fromMap(const {'active': true}).secure,
      isNull,
    );
    expect(
      WindowsTextInputDecision.fromMap(
        const {'active': false, 'secure': true},
      ).secure,
      isNull,
    );
  });
}
