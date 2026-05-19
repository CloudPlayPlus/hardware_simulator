# hardware_simulator

This plugin simulates mouse & keyboard input. Currently it is not well documented. 

Current it supports to simulate: mouse & keyboard for Windows/macOS/Linux (Linux mouse uses uinput via inputtino; Linux keyboard still requires X11 + XTest). XBOX Game Controller for windows. See the example for details.

Linux uinput permission setup:

```bash
./scripts/setup_linux_input_permissions.sh
```

Log out and back in after adding your user to the `input` group.

Any pull request is welcome. It is designed for https://github.com/zhuhaichao518/cloudplayplus_stone.
