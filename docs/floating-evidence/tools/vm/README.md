# t4 VM-service UI driver (evidence tool)

These scripts drive a **debug** build of Loop through the Dart VM Service without
touching OS input (important when another fullscreen app owns the desktop):

- `vm_probe.dart` — read logical/physical viewport, DPR, floating mode, ChatScreenState
  identity (same State across normal↔floating), Shell state.
- `vm_ui.dart` — locate widgets by `Key`/text, inject Flutter pointer events
  (`GestureBinding.handlePointerEvent`, scheduled in a microtask so it never runs
  inside a frame), set the chat input text, and script screenshot/stop/approval flows.

Setup (outside the product repo; any directory):

```powershell
# requires the Flutter SDK's dart; vm_service is already in the pub cache
# (adjust the path dependency to your pub cache version)
dart pub get
```

Usage:

```powershell
# VM Service URI is printed by `flutter run -d windows --debug`
dart run bin/vm_probe.dart "ws://127.0.0.1:<port>/<token>/ws" baseline
dart run bin/vm_ui.dart  "ws://127.0.0.1:<port>/<token>/ws" state
dart run bin/vm_ui.dart  "ws://127.0.0.1:<port>/<token>/ws" tap-key window-floating-toggle
dart run bin/vm_ui.dart  "ws://127.0.0.1:<port>/<token>/ws" keepalive-flow
dart run bin/vm_ui.dart  "ws://127.0.0.1:<port>/<token>/ws" screenshot-flow 1800 "100,100,500,400"
```

Notes:
- Pointer events need a unique `device` id per sequence; reusing a device after a
  failed/partial sequence trips MouseTracker's debug assertions (and poisons the
  tracker for the process).
- Flutter debug expression evaluation accepts only single-line expressions; these
  helpers flatten newlines before sending.
- Text input is set through `ChatScreenState` (`_controller.text`) because the test
  desktop is owned by a foreground fullscreen application; send/preview/stream are
  still driven through real widget hit-testing.
