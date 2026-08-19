enum MultiDisplayMode { extend, primaryOnly, secondaryOnly, duplicate, unknown }

class DisplayData {
  final int index;
  final int width;
  final int height;
  final int refreshRate;
  final bool isVirtual;
  final String displayName;
  final String deviceName;
  final bool active;
  final int displayUid;
  final int orientation;
  final int left;
  final int top;
  final int right;
  final int bottom;
  final bool isPrimary;
  final String? platformDisplayId;
  final int? inputScreenId;

  DisplayData({
    required this.index,
    required this.width,
    required this.height,
    required this.refreshRate,
    required this.isVirtual,
    required this.displayName,
    required this.deviceName,
    required this.active,
    required this.displayUid,
    required this.orientation,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.isPrimary,
    this.platformDisplayId,
    this.inputScreenId,
  });

  factory DisplayData.fromMap(Map<String, dynamic> map) {
    return DisplayData(
      index: map['index'] ?? 0,
      width: map['width'] ?? 1920,
      height: map['height'] ?? 1080,
      refreshRate: map['refreshRate'] ?? 60,
      isVirtual: map['isVirtual'] ?? false,
      displayName: map['displayName'] ?? '',
      deviceName: map['deviceName'] ?? '',
      active: map['active'] ?? true,
      displayUid: map['displayUid'] ?? 0,
      orientation: map['orientation'] ?? 0,
      left: map['left'] ?? 0,
      top: map['top'] ?? 0,
      right: map['right'] ?? 0,
      bottom: map['bottom'] ?? 0,
      isPrimary: map['isPrimary'] ?? false,
      platformDisplayId: map['platformDisplayId'] is String &&
              (map['platformDisplayId'] as String).isNotEmpty
          ? map['platformDisplayId'] as String
          : null,
      inputScreenId:
          map['inputScreenId'] is int && (map['inputScreenId'] as int) >= 0
              ? map['inputScreenId'] as int
              : null,
    );
  }
}
