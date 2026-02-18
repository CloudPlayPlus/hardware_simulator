import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hardware_simulator/hardware_simulator.dart';
import 'package:hardware_simulator/hardware_simulator_platform_interface.dart';

class FPSGameExample extends StatefulWidget {
  const FPSGameExample({Key? key}) : super(key: key);

  @override
  State<FPSGameExample> createState() => _FPSGameExampleState();
}

class _FPSGameExampleState extends State<FPSGameExample> {
  bool _isCursorLocked = false;
  double _cameraX = 0.0;
  double _cameraY = 0.0;

  void cursorMovedCallback(deltax, deltay) {
    if (_isCursorLocked) {
      setState(() {
        _cameraX += deltax * 0.1;
        _cameraY += deltay * 0.1;
      });
    }
  }

  void cursorPressedCallback(button, isDown) {
    if (_isCursorLocked) {
      print(button);
      print(isDown);
    }
  }

  @override
  void initState() {
    super.initState();
    // 初始化硬件模拟器
    HardwareSimulator.registerService();
    HardwareSimulator.addCursorMoved(cursorMovedCallback);
    HardwareSimulator.addCursorPressed(cursorPressedCallback);
  }

  @override
  void dispose() {
    // 解锁光标
    if (_isCursorLocked) {
      HardwareSimulator.unlockCursor();
    }
    super.dispose();
  }

  void _toggleCursorLock() {
    setState(() {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      if (_isCursorLocked) {
        HardwareSimulator.unlockCursor();
      } else {
        HardwareSimulator.lockCursor();
      }
      _isCursorLocked = !_isCursorLocked;
    });
  }

  void _handlePointerMove(PointerMoveEvent event) {
    /*if (_isCursorLocked) {
      setState(() {
        _cameraX += event.delta.dx * 0.1;
        _cameraY += event.delta.dy * 0.1;
      });
    }*/
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // 游戏场景
          MouseRegion(
            cursor: _isCursorLocked
                ? SystemMouseCursors.none
                : SystemMouseCursors.basic,
            child: Listener(
              onPointerMove: _handlePointerMove,
              child: Container(
                color: Colors.black,
                child: Center(
                  child: Transform(
                    transform: Matrix4.identity()
                      ..rotateX(_cameraY)
                      ..rotateY(_cameraX),
                    child: const Icon(
                      Icons.games,
                      size: 100,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 控制按钮
          Positioned(
            bottom: 20,
            right: 20,
            child: ElevatedButton(
              onPressed: _toggleCursorLock,
              child: Text(_isCursorLocked ? '解锁光标' : '锁定光标'),
            ),
          ),

          // 状态显示
          Positioned(
            top: 20,
            left: 20,
            child: Text(
              '相机角度: X: ${_cameraX.toStringAsFixed(2)}, Y: ${_cameraY.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
