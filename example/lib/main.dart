import 'dart:ui' as ui show Image, decodeImageFromPixels, PixelFormat;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:hardware_simulator/hardware_simulator.dart';

import 'package:url_launcher/url_launcher.dart';
import 'fps_game_example.dart';
import 'display_manager_page.dart';
import 'immersive_mode_example.dart';

void main() {
  //SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('Hardware Simulator')),
        body: SimulatorScreen(),
      ),
    );
  }
}

class SimulatorScreen extends StatefulWidget {
  @override
  _SimulatorScreenState createState() => _SimulatorScreenState();
}

class _SimulatorScreenState extends State<SimulatorScreen> {
  final TextEditingController xController = TextEditingController();
  final TextEditingController yController = TextEditingController();
  final TextEditingController relXController = TextEditingController();
  final TextEditingController relYController = TextEditingController();
  final TextEditingController keyController = TextEditingController();
  final TextEditingController touchXController = TextEditingController();
  final TextEditingController touchYController = TextEditingController();
  final TextEditingController touchIdController = TextEditingController();

  final TextEditingController penXController = TextEditingController();
  final TextEditingController penYController = TextEditingController();
  final TextEditingController penPressureController =
      TextEditingController(text: '0.5');
  final TextEditingController penRotationController =
      TextEditingController(text: '0');
  final TextEditingController penTiltController =
      TextEditingController(text: '0');

  final HardwareSimulator hardwareSimulator = HardwareSimulator();

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      print('Key Down: ${event.logicalKey}');
    } else if (event is KeyUpEvent) {
      print('Key Up: ${event.logicalKey}');
    } else {
      print('repeat ${event.logicalKey}');
    }
    return true;
  }

  void _moveMouseAbsolute() {
    double x = double.tryParse(xController.text) ?? 0;
    double y = double.tryParse(yController.text) ?? 0;
    hardwareSimulator.getMouse().performMouseMoveAbsl(x, y, 0);
    //hardwareSimulator.getMouse().performMouseMoveToWindowPosition(x, y);
  }

  void _moveMouseRelative() {
    double deltaX = double.tryParse(relXController.text) ?? 0;
    double deltaY = double.tryParse(relYController.text) ?? 0;
    hardwareSimulator.getMouse().performMouseMoveRelative(deltaX, deltaY, 0);
  }

  void _pressKey() {
    _transferFocus();
    int keyCode = int.tryParse(keyController.text) ??
        0; // Assuming key code is an integer
    hardwareSimulator
        .getKeyboard()
        .performKeyEvent(keyCode, true); // Press down
    Future.delayed(Duration(milliseconds: 100), () {
      hardwareSimulator
          .getKeyboard()
          .performKeyEvent(keyCode, false); // Release
    });
  }

  ui.Image? image;

  Map<int, ui.Image> cached_images = {};

  Future<ui.Image> rawBGRAtoImage(
      Uint8List bytes, int width, int height) async {
    final Completer<ui.Image> completer = Completer();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.bgra8888,
      (ui.Image img) {
        return completer.complete(img);
      },
    );
    return completer.future;
  }

  void updateCursorImage(Uint8List message, int width, int height, int hash) {
    rawBGRAtoImage(message, width, height).then((ui.Image img) {
      setState(() {
        cached_images[hash] = img;
        image = img; // 在setState中更新image
      });
    });
  }

  void _registerCursorChanged() async {
    HardwareSimulator.addCursorImageUpdated(
        (int message, int messageInfo, Uint8List cursorImage) {
      if (message == HardwareSimulator.CURSOR_UPDATED_IMAGE) {
        //cursor hash: 0 + size + hash + data
        int width = 0;
        int height = 0;
        int hash = 0;
        int hotx = 0;
        int hoty = 0;
        //We may use the 0 bit for future use to indicate some image type.
        if (cursorImage[0] == 9) {
          //cursor bitmap
          for (int i = 1; i < 5; i++) {
            width = width * 256 + cursorImage[i];
          }
          for (int i = 5; i < 9; i++) {
            height = height * 256 + cursorImage[i];
          }
          for (int i = 9; i < 13; i++) {
            hotx = hotx * 256 + cursorImage[i];
          }
          for (int i = 13; i < 17; i++) {
            hoty = hoty * 256 + cursorImage[i];
          }
          for (int i = 17; i < 21; i++) {
            hash = hash * 256 + cursorImage[i];
          }
          updateCursorImage(cursorImage.sublist(21), width, height, hash);
        }
      } else if (message == HardwareSimulator.CURSOR_VISIBLE) {
        // 获取显示器ID和鼠标位置信息
        int screenId = messageInfo;

        // 检查是否有位置数据（新版本有8字节，旧版本可能为空）
        if (cursorImage.isNotEmpty && cursorImage.length >= 8) {
          ByteData byteData = ByteData.sublistView(cursorImage);
          double xPercent = byteData.getFloat32(0, Endian.little);
          double yPercent = byteData.getFloat32(4, Endian.little);

          print(
              'Cursor became visible - Screen ID: $screenId, X: ${(xPercent * 100).toStringAsFixed(1)}%, Y: ${(yPercent * 100).toStringAsFixed(1)}%');
        } else {
          // 兼容旧版本，没有位置数据
          print(
              'Cursor became visible - Screen ID: $screenId (no position data)');
        }
      } else if (message == HardwareSimulator.CURSOR_UPDATED_CACHED) {
        setState(() {
          image = cached_images[messageInfo]; // 在setState中更新image
        });
      }
    }, 1, true);
  }

  void _registerTrackCursor() async {
    if (Platform.isIOS) {
      HardwareSimulator.addCursorMoved((double dx, double dy) {
        print('Cursor moved: dx=$dx, dy=$dy');
      });
    }
  }

  void _unregisterTrackCursor() async {
    if (Platform.isIOS) {
      HardwareSimulator.removeCursorMoved((double dx, double dy) {
        print('Cursor moved: dx=$dx, dy=$dy');
      });
    }
  }

  void _unregisterCursorChanged() async {
    HardwareSimulator.removeCursorImageUpdated(1);
  }

  // 鼠标位置监控相关变量
  bool _positionMonitoringActive = false;

  void _startPositionMonitoring() async {
    if (_positionMonitoringActive) return;

    _positionMonitoringActive = true;
    HardwareSimulator.addCursorPositionUpdated(
        (message, screenId, xPercent, yPercent) {
      if (message == HardwareSimulator.CURSOR_POSITION_CHANGED) {
        print(
            '鼠标位置变化 - 屏幕ID: $screenId, X: ${(xPercent * 100).toStringAsFixed(1)}%, Y: ${(yPercent * 100).toStringAsFixed(1)}%');
      }
    }, 2); // 使用回调ID 2

    print('鼠标位置监控已启动');
  }

  void _stopPositionMonitoring() async {
    if (!_positionMonitoringActive) return;

    HardwareSimulator.removeCursorPositionUpdated(2);
    _positionMonitoringActive = false;
    print('鼠标位置监控已停止');
  }

  FocusNode? _textFieldFocusNode;

  @override
  void initState() {
    super.initState();
    // 监听硬件键盘事件
    //HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    _textFieldFocusNode = FocusNode();
    _registerTrackCursor(); // 注册trackCursor回调
  }

  @override
  void dispose() {
    //HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _textFieldFocusNode?.dispose();
    _unregisterCursorChanged();
    _unregisterTrackCursor(); // 注销trackCursor回调
    _stopPositionMonitoring(); // 停止鼠标位置监控
    super.dispose();
  }

  void _transferFocus() {
    FocusScope.of(context).requestFocus(_textFieldFocusNode);
  }

  void _openWebPage() async {
    await launchUrl(
        Uri.parse('https://timmaffett.github.io/custom_mouse_cursor/#/'));
  }

  GameController? controller;

  void _insertGameController() async {
    controller = await HardwareSimulator.createGameController();
  }

  void _removeGameController() async {
    await controller?.dispose();
    controller = null;
  }

  void _pressAbutton() async {
    //"xinput: $word $bLeftTrigger $bRightTrigger $sThumbLX $sThumbLY $sThumbRX $sThumbRY "
    controller?.simulate("1 0 0 0 0 0 0");
  }

  void _releaseAbutton() async {
    //"xinput: $word $bLeftTrigger $bRightTrigger $sThumbLX $sThumbLY $sThumbRX $sThumbRY "
    controller?.simulate("0 0 0 0 0 0 0");
  }

  void _showNotification() async {
    HardwareSimulator.showNotification("啦啦啦");
  }

  void _touchDown() {
    double x = double.tryParse(touchXController.text) ?? 0;
    double y = double.tryParse(touchYController.text) ?? 0;
    int touchId = int.tryParse(touchIdController.text) ?? 1;
    HardwareSimulator.performTouchEvent(x, y, touchId, true, 0);
  }

  void _touchMove() {
    double x = double.tryParse(touchXController.text) ?? 0;
    double y = double.tryParse(touchYController.text) ?? 0;
    int touchId = int.tryParse(touchIdController.text) ?? 1;
    HardwareSimulator.performTouchMove(x, y, touchId, 0);
  }

  void _touchUp() {
    double x = double.tryParse(touchXController.text) ?? 0;
    double y = double.tryParse(touchYController.text) ?? 0;
    int touchId = int.tryParse(touchIdController.text) ?? 1;
    HardwareSimulator.performTouchEvent(x, y, touchId, false, 0);
  }

  void _penDown() {
    double x = double.tryParse(penXController.text) ?? 0;
    double y = double.tryParse(penYController.text) ?? 0;
    double pressure = double.tryParse(penPressureController.text) ?? 0.5;
    double rotation = double.tryParse(penRotationController.text) ?? 0;
    double tilt = double.tryParse(penTiltController.text) ?? 0;
    HardwareSimulator.performPenEvent(
        x, y, true, false, pressure, rotation, tilt, 0);
  }

  void _penMove() {
    double x = double.tryParse(penXController.text) ?? 0;
    double y = double.tryParse(penYController.text) ?? 0;
    double pressure = double.tryParse(penPressureController.text) ?? 0.5;
    double rotation = double.tryParse(penRotationController.text) ?? 0;
    double tilt = double.tryParse(penTiltController.text) ?? 0;
    HardwareSimulator.performPenMove(x, y, false, pressure, rotation, tilt, 0);
  }

  void _penUp() {
    double x = double.tryParse(penXController.text) ?? 0;
    double y = double.tryParse(penYController.text) ?? 0;
    double pressure = double.tryParse(penPressureController.text) ?? 0.5;
    double rotation = double.tryParse(penRotationController.text) ?? 0;
    double tilt = double.tryParse(penTiltController.text) ?? 0;
    HardwareSimulator.performPenEvent(
        x, y, false, false, pressure, rotation, tilt, 0);
  }

  void _setDragWindowContents(bool enabled) {
    HardwareSimulator.setDragWindowContents(enabled);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // 添加导航按钮到FPS游戏示例页面
        ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => FPSGameExample()),
            );
          },
          child: Text('进入FPS游戏示例(windows需先进入沉浸模式)'),
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            textStyle: TextStyle(fontSize: 18),
          ),
        ),
        // 添加导航按钮到显示器管理页面
        ElevatedButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => DisplayManagerPage()),
            );
          },
          child: Text('显示器管理'),
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            textStyle: TextStyle(fontSize: 18),
          ),
        ),
        if (Platform.isWindows)
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => ImmersiveModeExample()),
              );
            },
            child: Text('沉浸模式'),
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              textStyle: TextStyle(fontSize: 18),
            ),
          ),
        SizedBox(height: 20),
        // First Row: Absolute Mouse Move
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
                child: TextField(
                    controller: xController,
                    decoration: InputDecoration(
                        labelText: 'X(0 - 1.0) (% from left)'))),
            Expanded(
                child: TextField(
                    controller: yController,
                    decoration:
                        InputDecoration(labelText: 'Y(0 - 1.0) (% from top)'))),
            ElevatedButton(
                onPressed: _moveMouseAbsolute,
                child: Text('Move Mouse to X, Y')),
            ElevatedButton(
                onPressed: _showNotification, child: Text('show notification')),
          ],
        ),
        SizedBox(height: 20),

        // Second Row: Relative Mouse Move
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
                child: TextField(
                    controller: relXController,
                    decoration: InputDecoration(labelText: 'Delta X'))),
            Expanded(
                child: TextField(
                    controller: relYController,
                    decoration: InputDecoration(labelText: 'Delta Y'))),
            ElevatedButton(
                onPressed: _moveMouseRelative,
                child: Text('Move Mouse Relative')),
          ],
        ),
        SizedBox(height: 20),
        // Third Row: Keyboard Action
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
                child: TextField(
                    controller: keyController,
                    decoration: InputDecoration(labelText: 'Key Code'))),
            ElevatedButton(
                onPressed: _pressKey,
                child: Text('Press to Simulate Keyboard Input')),
          ],
        ),
        SizedBox(height: 20),
        TextField(
          focusNode: _textFieldFocusNode,
          decoration: InputDecoration(
            hintText: 'Simulated keyboard input',
          ),
        ),
        SizedBox(height: 20),
        // Second Row: Relative Mouse Move
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
                child: image == null
                    ? CircularProgressIndicator()
                    : CustomPaint(
                        painter: ImagePainter(image!),
                        size: Size(
                            image!.width.toDouble(), image!.height.toDouble()),
                      )),
            ElevatedButton(
                //https://timmaffett.github.io/custom_mouse_cursor/#/
                onPressed: _openWebPage,
                child: Text('open test cursor web')),
            ElevatedButton(
                onPressed: _registerCursorChanged,
                child: Text('register CursorImageChanged')),
            ElevatedButton(
                onPressed: _unregisterCursorChanged,
                child: Text('unregister CursorImageChanged')),
          ],
        ),
        // 鼠标位置监控按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed:
                  _positionMonitoringActive ? null : _startPositionMonitoring,
              child: Text('开始监控鼠标位置'),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed:
                  _positionMonitoringActive ? _stopPositionMonitoring : null,
              child: Text('停止监控鼠标位置'),
            ),
          ],
        ),
        SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
                //https://timmaffett.github.io/custom_mouse_cursor/#/
                onPressed: _insertGameController,
                child: Text('plug in game controller')),
            ElevatedButton(
                onPressed: _removeGameController,
                child: Text('plug out game controller')),
            ElevatedButton(
                onPressed: _pressAbutton, child: Text('press up button')),
            ElevatedButton(
                onPressed: _releaseAbutton, child: Text('release up button')),
          ],
        ),
        SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: touchXController,
                decoration: InputDecoration(labelText: 'Touch X (0-1)'),
                keyboardType: TextInputType.number,
              ),
            ),
            Expanded(
              child: TextField(
                controller: touchYController,
                decoration: InputDecoration(labelText: 'Touch Y (0-1)'),
                keyboardType: TextInputType.number,
              ),
            ),
            Expanded(
              child: TextField(
                controller: touchIdController,
                decoration: InputDecoration(labelText: 'Touch ID'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _touchDown,
              child: Text('Touch Down'),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed: _touchMove,
              child: Text('Touch Move'),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed: _touchUp,
              child: Text('Touch Up'),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () {
                _setDragWindowContents(true);
              },
              child: Text('setDragWindowContents true'),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed: () {
                _setDragWindowContents(false);
              },
              child: Text('setDragWindowContents false'),
            ),
          ],
        ),
        SizedBox(height: 20),
        // Pen input section
        Text(
          'Pen Input Test',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: penXController,
                decoration: InputDecoration(labelText: 'Pen X (0-1)'),
                keyboardType: TextInputType.number,
              ),
            ),
            Expanded(
              child: TextField(
                controller: penYController,
                decoration: InputDecoration(labelText: 'Pen Y (0-1)'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Expanded(
              child: TextField(
                controller: penPressureController,
                decoration: InputDecoration(labelText: 'Pressure (0-1)'),
                keyboardType: TextInputType.number,
              ),
            ),
            Expanded(
              child: TextField(
                controller: penRotationController,
                decoration: InputDecoration(labelText: 'Rotation (0-360)'),
                keyboardType: TextInputType.number,
              ),
            ),
            Expanded(
              child: TextField(
                controller: penTiltController,
                decoration: InputDecoration(labelText: 'Tilt (0-90)'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _penDown,
              child: Text('Pen Down'),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed: _penMove,
              child: Text('Pen Move'),
            ),
            SizedBox(width: 10),
            ElevatedButton(
              onPressed: _penUp,
              child: Text('Pen Up'),
            ),
          ],
        ),
      ],
    );
  }
}

class ImagePainter extends CustomPainter {
  final ui.Image image;

  ImagePainter(this.image);

  @override
  void paint(Canvas canvas, Size size) {
    // 在画布上绘制图片
    canvas.drawImage(image, Offset.zero, Paint());
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
