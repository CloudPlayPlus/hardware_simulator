# hardware_simulator

This plugin simulates mouse & keyboard input. Currently it is not well documented. 

Current it supports to simulate: mouse & keyboard for Windows/macOS/Linux (Linux mouse uses uinput via inputtino; Linux keyboard still requires X11 + XTest). XBOX Game Controller for windows. See the example for details.

Linux uinput permission setup:

```bash
sudo install -m 0644 linux/udev/rules.d/60-cloudplayplus-hardware-simulator.rules /etc/udev/rules.d/
sudo groupadd -f input
sudo usermod -aG input "$USER"
sudo modprobe uinput
sudo udevadm control --reload-rules
sudo udevadm trigger --property-match=DEVNAME=/dev/uinput
```

Log out and back in after adding your user to the `input` group.

Any pull request is welcome. It is designed for https://github.com/zhuhaichao518/cloudplayplus_stone.
