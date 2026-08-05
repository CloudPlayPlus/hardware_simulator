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

  test('performTextInput sends committed text without transformation',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );

    await platform.performTextInput('你好 👋');

    expect(calls, hasLength(1));
    expect(calls.single.method, 'performTextInput');
    expect(calls.single.arguments, {'text': '你好 👋'});
  });

  test('pointer contact-up carries the edit-focus request id', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return null;
      },
    );

    await platform.performMouseClick(
      1,
      false,
      editFocusRequestId: 41,
    );
    await platform.performTouchEvent(
      0.25,
      0.75,
      2,
      false,
      1,
      editFocusRequestId: 42,
    );
    await platform.performPenEvent(
      0.5,
      0.6,
      false,
      false,
      0.8,
      0,
      0,
      1,
      editFocusRequestId: 43,
    );

    expect(calls[0].arguments, {
      'buttonId': 1,
      'isDown': false,
      'editFocusRequestId': 41,
    });
    expect(calls[1].arguments, {
      'x': 0.25,
      'y': 0.75,
      'touchId': 2,
      'isDown': false,
      'screenId': 1,
      'editFocusRequestId': 42,
    });
    expect(calls[2].arguments, {
      'x': 0.5,
      'y': 0.6,
      'isDown': false,
      'hasButton': false,
      'pressure': 0.8,
      'rotation': 0.0,
      'tilt': 0.0,
      'screenId': 1,
      'editFocusRequestId': 43,
    });
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

  test('first and last text input listeners manage native capture', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        calls.add(methodCall);
        return methodCall.method == 'startTextInputDecisionCapture';
      },
    );

    void firstListener(TextInputDecision _) {}
    void secondListener(TextInputDecision _) {}
    platform.addTextInputDecision(firstListener);
    platform.addTextInputDecision(firstListener);
    platform.addTextInputDecision(secondListener);
    await Future<void>.delayed(Duration.zero);

    platform.removeTextInputDecision(firstListener);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls.map((call) => call.method),
      ['startTextInputDecisionCapture'],
    );

    platform.removeTextInputDecision(secondListener);
    await Future<void>.delayed(Duration.zero);
    expect(
      calls.map((call) => call.method),
      [
        'startTextInputDecisionCapture',
        'stopTextInputDecisionCapture',
      ],
    );
  });

  test('decodes minimal text input decisions', () async {
    TextInputDecision? received;
    late TextInputDecisionCallback listener;
    listener = (decision) {
      received = decision;
      platform.removeTextInputDecision(listener);
    };
    platform.addTextInputDecision(listener);

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'hardware_simulator',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onTextInputDecision', <String, dynamic>{
          'active': true,
          'secure': false,
          'editFocusRequestId': 42,
        }),
      ),
      null,
    );

    expect(received, isNotNull);
    expect(received!.active, isTrue);
    expect(received!.secure, isFalse);
    expect(received!.editFocusRequestId, 42);
    await Future<void>.delayed(Duration.zero);
  });

  test('normalizes unknown and inactive secure state to null', () {
    expect(
      TextInputDecision.fromMap(const {'active': true}).secure,
      isNull,
    );
    expect(
      TextInputDecision.fromMap(
        const {'active': false, 'secure': true},
      ).secure,
      isNull,
    );
  });
}
