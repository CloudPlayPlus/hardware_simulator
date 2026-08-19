import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_simulator/display_data.dart';

void main() {
  test('parses catalog display and input target identifiers', () {
    final display = DisplayData.fromMap({
      'index': 9,
      'platformDisplayId': r'win:path:\\?\DISPLAY#DEL4098',
      'captureDisplayId': r'\\.\DISPLAY2',
      'inputScreenId': 1,
    });

    expect(display.index, 9);
    expect(
      display.platformDisplayId,
      r'win:path:\\?\DISPLAY#DEL4098',
    );
    expect(display.captureDisplayId, r'\\.\DISPLAY2');
    expect(display.inputScreenId, 1);
  });

  test('keeps resolver identifiers absent for older backends', () {
    final display = DisplayData.fromMap(const {});

    expect(display.platformDisplayId, isNull);
    expect(display.captureDisplayId, isNull);
    expect(display.inputScreenId, isNull);
  });
}
