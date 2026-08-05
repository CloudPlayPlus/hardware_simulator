## Unreleased

* Add event-driven macOS editable-focus detection and Unicode text injection.
* Generalize the editable-focus decision API for Windows and macOS hosts.
* Derive injected macOS keyboard flags from remote pressed modifiers so
  back-to-back shortcuts keep their Command/Control state reliably.
* Inject macOS Caps Lock as explicit AlphaShift state changes so repeated
  presses can switch input sources in both directions.
* Define a cross-platform logical scroll contract and convert it at each
  native host boundary.
* Move Windows scroll magnitude normalization to the Dart host layer; the
  native adapter now applies direction and safety clamping only.

## 0.0.1

* TODO: Describe initial release.
