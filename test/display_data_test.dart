import 'package:flutter_test/flutter_test.dart';
import 'package:hardware_simulator/display_data.dart';

void main() {
  test('parses the raw Windows screen id independently from list index', () {
    final display = DisplayData.fromMap(<String, dynamic>{
      'index': 1,
      'rawScreenId': 8,
    });

    expect(display.index, 1);
    expect(display.rawScreenId, 8);
  });

  test('defaults raw screen id for older platform implementations', () {
    final display = DisplayData.fromMap(const <String, dynamic>{});

    expect(display.rawScreenId, -1);
  });
}
