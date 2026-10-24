// t4 floating window VM-service UI driver.
// Injects real Flutter pointer events into the running debug isolate (no OS input,
// so it cannot disturb the foreground game/window) and reads on-screen rects by key/text.
//
// usage: dart run bin/vm_ui.dart <ws-uri> <command> [args...]
//   ping
//   state
//   find-key <key>
//   find-text <substring>
//   tap-key <key>
//   tap-text <substring>
//   tap <x> <y>
//   drag <x1> <y1> <x2> <y2> [steps]
//   scroll <x> <y> <dy>
//   text <value>                # set chat controller text (simulates typed input)
//   tap-send                    # tap chat-send-stop key
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

late VmService service;
late String isolateId;
late String rootLibId;
late String gestureLibId;

Future<String> evaluateOn(String targetId, String expression) async {
  // Flutter debug expression compiler only supports single-line expressions.
  final flat = expression.replaceAll('\r', ' ').replaceAll('\n', ' ');
  final response = await service.evaluate(isolateId, targetId, flat);
  final ref = InstanceRef.parse(response.json!);
  return ref?.valueAsString ?? '<no value>';
}

Future<Map<String, Object?>> stateMap() async {
  final classes = await service.getClassList(isolateId);
  final out = <String, Object?>{
    'views': await evaluateOn(rootLibId,
        '(WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.toString() + " @" + '
        'WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio.toString())'),
    'mode': await evaluateOn(rootLibId, 'WindowController.instance.floating.mode.name'),
    'pinned': await evaluateOn(rootLibId, 'WindowController.instance.floating.pinned.toString()'),
    'transitioning':
        await evaluateOn(rootLibId, 'WindowController.instance.floating.transitioning.toString()'),
    'captureInProgress':
        await evaluateOn(rootLibId, 'WindowController.instance.floating.captureInProgress.toString()'),
  };
  for (final cls in classes.classes ?? <ClassRef>[]) {
    if (cls.name == 'ChatScreenState' && cls.id != null) {
      final instances = await service.getInstances(isolateId, cls.id!, 10);
      final list = <Map<String, Object?>>[];
      for (final ref in instances.instances ?? <ObjRef>[]) {
        final id = ref.id!;
        final fields = <String, Object?>{};
        for (final entry in {
          'conversationId': 'conversationId',
          'messageCount': 'messageCount',
          'attachmentCount': 'attachmentCount',
          'isSending': 'isSending',
          'isGenerating': 'isGenerating',
          'approvalVisible': 'approvalVisible',
          'floating': 'widget.floating',
          'compact': 'widget.compact',
        }.entries) {
          fields[entry.key] = await evaluateOn(id, entry.value);
        }
        fields['objectId'] = id;
        fields['identityHashCode'] = ref is InstanceRef ? ref.identityHashCode : null;
        list.add(fields);
      }
      out['chatStates'] = list;
    }
    if (cls.name == '_ShellState' && cls.id != null) {
      final instances = await service.getInstances(isolateId, cls.id!, 10);
      final list = <Map<String, Object?>>[];
      for (final ref in instances.instances ?? <ObjRef>[]) {
        final id = ref.id!;
        list.add({
          'objectId': id,
          'index': await evaluateOn(id, '_index'),
          'wasFloating': await evaluateOn(id, '_wasFloating'),
          'identityHashCode': ref is InstanceRef ? ref.identityHashCode : null,
        });
      }
      out['shellStates'] = list;
    }
  }
  return out;
}

String finderExpression(String matcher) {
  return '''
(() {
  String? result;
  void walk(Element e) {
    if (result != null) return;
    if ($matcher) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        final off = ro.localToGlobal(Offset.zero);
        result = '\${off.dx},\${off.dy},\${ro.size.width},\${ro.size.height}';
      }
      return;
    }
    e.visitChildren(walk);
  }
  walk(WidgetsBinding.instance.rootElement!);
  return result ?? 'not-found';
})()
''';
}

Future<String> findWithin(String containerKey, String matcher) async {
  final expr = '''
(() {
  String? result;
  Element? container;
  void findContainer(Element e) {
    if (container != null) return;
    final k = e.widget.key;
    if (k is ValueKey<String> && k.value == '$containerKey') { container = e; return; }
    e.visitChildren(findContainer);
  }
  findContainer(WidgetsBinding.instance.rootElement!);
  if (container == null) return 'container-not-found';
  void walk(Element e) {
    if (result != null) return;
    if ($matcher) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        final off = ro.localToGlobal(Offset.zero);
        result = '\${off.dx},\${off.dy},\${ro.size.width},\${ro.size.height}';
      }
      return;
    }
    e.visitChildren(walk);
  }
  walk(container!);
  return result ?? 'not-found';
})()
''';
  return evaluateOn(rootLibId, expr);
}

Future<String> findTextWithin(String containerKey, String text) => findWithin(
    containerKey,
    "e.widget is Text && (((e.widget as Text).data ?? '').contains('${text.replaceAll("'", "\\'")}'))");

Future<String> findTextAll(String text) async {
  final expr = '''
(() {
  final out = <String>[];
  void walk(Element e) {
    if (e.widget is Text && (((e.widget as Text).data ?? '').contains('${text.replaceAll("'", "\\'")}'))) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        final off = ro.localToGlobal(Offset.zero);
        out.add('\${off.dx},\${off.dy},\${ro.size.width},\${ro.size.height}');
      }
    }
    e.visitChildren(walk);
  }
  walk(WidgetsBinding.instance.rootElement!);
  return out.join(';');
})()
''';
  return evaluateOn(rootLibId, expr);
}

Future<String> findKey(String key) => evaluateOn(
    rootLibId,
    finderExpression(
        "e.widget.key is ValueKey<String> && (e.widget.key as ValueKey<String>).value == '${key.replaceAll("'", "\\'")}'"));

Future<String> findText(String text) => evaluateOn(
    rootLibId,
    finderExpression(
        "e.widget is Text && (((e.widget as Text).data ?? '').contains('${text.replaceAll("'", "\\'")}'))"));

String pointerDown(String x, String y) =>
    "GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 77, position: Offset($x, $y), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton)); ";

String pointerUp(String x, String y) =>
    "GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 77, position: Offset($x, $y), kind: PointerDeviceKind.mouse)); ";

Future<void> tapAt(double x, double y) async {
  final pid = 1000 + (DateTime.now().microsecondsSinceEpoch % 500000);
  final expr = '''
(() {
  scheduleMicrotask(() {
    try {
      final b = GestureBinding.instance;
      b.handlePointerEvent(PointerAddedEvent(pointer: $pid, device: $pid, position: Offset($x, $y), kind: PointerDeviceKind.mouse));
      b.handlePointerEvent(PointerDownEvent(pointer: $pid, device: $pid, position: Offset($x, $y), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton));
      b.handlePointerEvent(PointerUpEvent(pointer: $pid, device: $pid, position: Offset($x, $y), kind: PointerDeviceKind.mouse));
      b.handlePointerEvent(PointerRemovedEvent(pointer: $pid, device: $pid, position: Offset($x, $y), kind: PointerDeviceKind.mouse));
    } catch (e) {
      debugPrint('vm-tap-error: ' + e.toString());
    }
  });
  return 'scheduled';
})()
''';
  stdout.writeln(await evaluateOn(gestureLibId, expr));
}

Future<void> dragAt(double x1, double y1, double x2, double y2, int steps) async {
  final pid = 1000 + (DateTime.now().microsecondsSinceEpoch % 500000);
  final buffer = StringBuffer();
  buffer.write('(() { scheduleMicrotask(() { try { final b = GestureBinding.instance; ');
  buffer.write('b.handlePointerEvent(PointerAddedEvent(pointer: $pid, device: $pid, position: Offset($x1, $y1), kind: PointerDeviceKind.mouse)); ');
  buffer.write('b.handlePointerEvent(PointerDownEvent(pointer: $pid, device: $pid, position: Offset($x1, $y1), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton)); ');
  for (var i = 1; i <= steps; i++) {
    final x = x1 + (x2 - x1) * i / steps;
    final y = y1 + (y2 - y1) * i / steps;
    buffer.write('b.handlePointerEvent(PointerMoveEvent(pointer: $pid, device: $pid, position: Offset($x, $y), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton)); ');
  }
  buffer.write('b.handlePointerEvent(PointerUpEvent(pointer: $pid, device: $pid, position: Offset($x2, $y2), kind: PointerDeviceKind.mouse)); ');
  buffer.write('b.handlePointerEvent(PointerRemovedEvent(pointer: $pid, device: $pid, position: Offset($x2, $y2), kind: PointerDeviceKind.mouse)); ');
  buffer.write("} catch (e) { debugPrint('vm-drag-error: \$e'); } }); return 'scheduled'; })()");
  stdout.writeln(await evaluateOn(gestureLibId, buffer.toString()));
}

Future<void> scrollAt(double x, double y, double dy) async {
  final pid = 1000 + (DateTime.now().microsecondsSinceEpoch % 500000);
  final expr = '''
(() {
  scheduleMicrotask(() {
    try {
      final b = GestureBinding.instance;
      b.handlePointerEvent(PointerScrollEvent(device: $pid, position: Offset($x, $y), kind: PointerDeviceKind.mouse, scrollDelta: Offset(0, $dy)));
    } catch (e) {
      debugPrint('vm-scroll-error: ' + e.toString());
    }
  });
  return 'scheduled';
})()
''';
  stdout.writeln(await evaluateOn(gestureLibId, expr));
}

Future<void> setText(String value) async {
  final classes = await service.getClassList(isolateId);
  for (final cls in classes.classes ?? <ClassRef>[]) {
    if (cls.name == 'ChatScreenState' && cls.id != null) {
      final instances = await service.getInstances(isolateId, cls.id!, 5);
      final ref = (instances.instances ?? <ObjRef>[]).firstOrNull;
      if (ref?.id == null) continue;
      final escaped = value.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n');
      final out = await evaluateOn(ref!.id!,
          "(() { _controller.text = '$escaped'; _controller.selection = TextSelection.collapsed(offset: _controller.text.length); _focus.requestFocus(); return _controller.text; })()");
      stdout.writeln(out);
      return;
    }
  }
  stdout.writeln('chat-state-not-found');
}

Future<String> coordsFor(String selector) async {
  late String found;
  if (selector.startsWith('key:')) {
    found = await findKey(selector.substring(4));
  } else if (selector.startsWith('text:')) {
    found = await findText(selector.substring(5));
  } else {
    throw ArgumentError('selector must be key:... or text:...');
  }
  return found;
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: vm_ui.dart <ws-uri> <command> [args]');
    exit(2);
  }
  service = await vmServiceConnectUri(args[0]);
  final vm = await service.getVM();
  final isolateRef = vm.isolates!.firstWhere(
    (iso) => iso.name == 'main' || (iso.name?.contains('main') ?? false),
    orElse: () => vm.isolates!.first,
  );
  isolateId = isolateRef.id!;
  final isolate = await service.getIsolate(isolateId);
  rootLibId = isolate.rootLib!.id!;
  // Pointer event classes are not imported by main.dart; hit-test/pointer injection
  // must be evaluated in a library that imports flutter/gestures + dart:ui.
  const gesturePreferred = [
    'package:flutter/src/widgets/binding.dart',
    'package:flutter/src/widgets/gesture_detector.dart',
    'package:flutter/src/gestures/binding.dart',
  ];
  String? gestureLib;
  for (final wanted in gesturePreferred) {
    for (final lib in isolate.libraries ?? <LibraryRef>[]) {
      if (lib.uri == wanted) {
        gestureLib = lib.id;
        break;
      }
    }
    if (gestureLib != null) break;
  }
  gestureLib ??= rootLibId;
  gestureLibId = gestureLib;

  final command = args[1];
  final rest = args.sublist(2);
  switch (command) {
    case 'raw':
      stdout.writeln(await evaluateOn(rootLibId, rest.join(' ')));
      break;
    case 'raw-lib':
      final target = rest[0];
      String? targetId;
      for (final lib in (await service.getIsolate(isolateId)).libraries ?? <LibraryRef>[]) {
        if ((lib.uri ?? '').contains(target)) {
          targetId = lib.id;
          break;
        }
      }
      if (targetId == null) {
        stdout.writeln('lib-not-found');
        exit(3);
      }
      stdout.writeln(await evaluateOn(targetId, rest.sublist(1).join(' ')));
      break;
    case 'ping':
      stdout.writeln(await evaluateOn(rootLibId, "'pong'"));
      break;
    case 'state':
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(await stateMap()));
      break;
    case 'state-json':
      stdout.writeln(jsonEncode(await stateMap()));
      break;
    case 'stop-flow':
      await setText('slow');
      var stopSend = (await findKey('chat-send-stop')).split(',');
      if (stopSend[0] == 'not-found') {
        stdout.writeln('send-not-found');
        exit(3);
      }
      await tapAt(double.parse(stopSend[0]) + double.parse(stopSend[2]) / 2,
          double.parse(stopSend[1]) + double.parse(stopSend[3]) / 2);
      stdout.writeln('sent');
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      stdout.writeln('before-stop: ${jsonEncode(await stateMap())}');
      final stopBtn = (await findKey('chat-send-stop')).split(',');
      if (stopBtn[0] == 'not-found') {
        stdout.writeln('stop-not-found');
        exit(3);
      }
      await tapAt(double.parse(stopBtn[0]) + double.parse(stopBtn[2]) / 2,
          double.parse(stopBtn[1]) + double.parse(stopBtn[3]) / 2);
      stdout.writeln('tapped-stop');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      stdout.writeln('after-stop: ${jsonEncode(await stateMap())}');
      break;
    case 'screenshot-cancel':
      final cwait = rest.isNotEmpty ? int.parse(rest[0]) : 1800;
      final sshot = (await findKey('floating-screenshot')).split(',');
      if (sshot[0] == 'not-found') {
        stdout.writeln('screenshot-button-not-found');
        exit(3);
      }
      await tapAt(double.parse(sshot[0]) + double.parse(sshot[2]) / 2,
          double.parse(sshot[1]) + double.parse(sshot[3]) / 2);
      await Future<void>.delayed(Duration(milliseconds: cwait));
      stdout.writeln('state-before-cancel: ${jsonEncode(await stateMap())}');
      final all = await findTextAll('取消');
      stdout.writeln('cancel-matches:$all');
      if (all == 'not-found' || all == 'container-not-found') {
        stdout.writeln('cancel-not-found');
        exit(3);
      }
      var bestY = -1.0;
      var bestRect = '';
      for (final item in all.split(';')) {
        final p = item.split(',');
        if (p.length != 4) continue;
        final y = double.parse(p[1]);
        if (y > bestY) {
          bestY = y;
          bestRect = item;
        }
      }
      final bp = bestRect.split(',');
      await tapAt(double.parse(bp[0]) + double.parse(bp[2]) / 2,
          double.parse(bp[1]) + double.parse(bp[3]) / 2);
      stdout.writeln('tapped-cancel');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      stdout.writeln('state-after-cancel: ${jsonEncode(await stateMap())}');
      break;
    case 'screenshot-flow':
      // Tap floating screenshot, wait for overlay, drag-select, confirm.
      final waitMs = rest.isNotEmpty ? int.parse(rest[0]) : 1800;
      var found = await findKey('floating-screenshot');
      var parts = found.split(',');
      if (parts[0] == 'not-found') {
        stdout.writeln('not-found:floating-screenshot');
        exit(3);
      }
      await tapAt(double.parse(parts[0]) + double.parse(parts[2]) / 2,
          double.parse(parts[1]) + double.parse(parts[3]) / 2);
      stdout.writeln('tapped-screenshot; waiting $waitMs ms');
      await Future<void>.delayed(Duration(milliseconds: waitMs));
      stdout.writeln('state-after-wait: ${jsonEncode(await stateMap())}');
      final overlay = await findKey('screenshot-overlay');
      stdout.writeln('overlay:$overlay');
      final doneRect = await findTextWithin('screenshot-overlay', '完成');
      final cancelRect = await findTextWithin('screenshot-overlay', '取消');
      stdout.writeln('done:$doneRect cancel:$cancelRect');
      if (rest.length > 1) {
        final coords = rest[1].split(',');
        final x1 = double.parse(coords[0]);
        final y1 = double.parse(coords[1]);
        final x2 = double.parse(coords[2]);
        final y2 = double.parse(coords[3]);
        await dragAt(x1, y1, x2, y2, 10);
        stdout.writeln('selected $x1,$y1 -> $x2,$y2');
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final done = await findTextWithin('screenshot-overlay', '完成');
        final dparts = done.split(',');
        if (dparts[0] == 'not-found') {
          stdout.writeln('done-not-found');
          exit(3);
        }
        await tapAt(double.parse(dparts[0]) + double.parse(dparts[2]) / 2,
            double.parse(dparts[1]) + double.parse(dparts[3]) / 2);
        stdout.writeln('tapped-done');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        stdout.writeln('state-after-done: ${jsonEncode(await stateMap())}');
      }
      break;
    case 'keepalive-flow':
      // send a slow message, toggle floating->normal->floating mid-stream, wait for completion.
      await setText('slow');
      var sendRect = (await findKey('chat-send-stop')).split(',');
      if (sendRect[0] == 'not-found') {
        stdout.writeln('send-not-found');
        exit(3);
      }
      await tapAt(double.parse(sendRect[0]) + double.parse(sendRect[2]) / 2,
          double.parse(sendRect[1]) + double.parse(sendRect[3]) / 2);
      stdout.writeln('sent');
      await Future<void>.delayed(const Duration(milliseconds: 900));
      stdout.writeln('after-send: ${jsonEncode(await stateMap())}');
      final backRect = (await findKey('floating-back')).split(',');
      if (backRect[0] != 'not-found') {
        await tapAt(double.parse(backRect[0]) + double.parse(backRect[2]) / 2,
            double.parse(backRect[1]) + double.parse(backRect[3]) / 2);
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      stdout.writeln('after-back: ${jsonEncode(await stateMap())}');
      final toggleRect = (await findKey('window-floating-toggle')).split(',');
      if (toggleRect[0] != 'not-found') {
        await tapAt(double.parse(toggleRect[0]) + double.parse(toggleRect[2]) / 2,
            double.parse(toggleRect[1]) + double.parse(toggleRect[3]) / 2);
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
      stdout.writeln('after-reenter: ${jsonEncode(await stateMap())}');
      for (var i = 0; i < 60; i++) {
        final current = await stateMap();
        final states = (current['chatStates'] as List?) ?? const [];
        final firstChat = states.isNotEmpty ? states.first as Map : const {};
        if (firstChat['isSending'] == 'false' && firstChat['isGenerating'] == 'false') {
          stdout.writeln('completed: ${jsonEncode(current)}');
          break;
        }
        if (i % 5 == 0) stdout.writeln('tick$i: ${jsonEncode(current)}');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      break;
    case 'pointer-debug':
      final dbgPid = 1000 + (DateTime.now().microsecondsSinceEpoch % 500000);
      final dbgX = double.parse(rest[0]);
      final dbgY = double.parse(rest[1]);
      final dbgExpr = '''
(() {
  final out = <String>[];
  final b = GestureBinding.instance;
  try { b.handlePointerEvent(PointerAddedEvent(pointer: $dbgPid, device: $dbgPid, position: Offset($dbgX, $dbgY), kind: PointerDeviceKind.mouse)); out.add('ADD-OK'); } catch (e) { out.add('ADD-ERR:' + e.toString().split('assertion:').last.trim().substring(0, 45)); }
  try { b.handlePointerEvent(PointerDownEvent(pointer: $dbgPid, device: $dbgPid, position: Offset($dbgX, $dbgY), kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton)); out.add('DOWN-OK'); } catch (e) { out.add('DOWN-ERR:' + e.toString().split('assertion:').last.trim().substring(0, 45)); }
  try { b.handlePointerEvent(PointerUpEvent(pointer: $dbgPid, device: $dbgPid, position: Offset($dbgX, $dbgY), kind: PointerDeviceKind.mouse)); out.add('UP-OK'); } catch (e) { out.add('UP-ERR:' + e.toString().split('assertion:').last.trim().substring(0, 45)); }
  try { b.handlePointerEvent(PointerRemovedEvent(pointer: $dbgPid, device: $dbgPid, position: Offset($dbgX, $dbgY), kind: PointerDeviceKind.mouse)); out.add('REM-OK'); } catch (e) { out.add('REM-ERR:' + e.toString().split('assertion:').last.trim().substring(0, 45)); }
  return out.join('|');
})()
''';
      stdout.writeln(await evaluateOn(gestureLibId, dbgExpr));
      break;
    case 'monitor':
      final seconds = double.parse(rest[0]);
      final interval = rest.length > 1 ? int.parse(rest[1]) : 250;
      final deadline = DateTime.now().add(Duration(milliseconds: (seconds * 1000).round()));
      while (DateTime.now().isBefore(deadline)) {
        stdout.writeln(jsonEncode(await stateMap()));
        await Future<void>.delayed(Duration(milliseconds: interval));
      }
      break;
    case 'find-text-all':
      final allExpr = '''
(() {
  final out = <String>[];
  void walk(Element e) {
    if (e.widget is Text && (((e.widget as Text).data ?? '').contains('${rest.join(' ').replaceAll("'", "\\'")}'))) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        final off = ro.localToGlobal(Offset.zero);
        out.add('\${off.dx},\${off.dy},\${ro.size.width},\${ro.size.height}');
      }
    }
    e.visitChildren(walk);
  }
  walk(WidgetsBinding.instance.rootElement!);
  return out.join(';');
})()
''';
      stdout.writeln(await evaluateOn(rootLibId, allExpr));
      break;
    case 'libs':
      for (final lib in (await service.getIsolate(isolateId)).libraries ?? <LibraryRef>[]) {
        if ((lib.uri ?? '').contains('gestures')) stdout.writeln('${lib.uri} -> ${lib.id}');
      }
      break;
    case 'find-key':
      stdout.writeln(await findKey(rest[0]));
      break;
    case 'find-text':
      stdout.writeln(await findText(rest.join(' ')));
      break;
    case 'tap-key':
      final found = await findKey(rest[0]);
      final parts = found.split(',');
      if (parts.length != 4 || parts[0] == 'not-found') {
        stdout.writeln('not-found:${rest[0]}');
        exit(3);
      }
      final x = double.parse(parts[0]) + double.parse(parts[2]) / 2;
      final y = double.parse(parts[1]) + double.parse(parts[3]) / 2;
      await tapAt(x, y);
      break;
    case 'tap-text':
      final found = await findText(rest.join(' '));
      final parts = found.split(',');
      if (parts.length != 4 || parts[0] == 'not-found') {
        stdout.writeln('not-found:${rest.join(' ')}');
        exit(3);
      }
      final x = double.parse(parts[0]) + double.parse(parts[2]) / 2;
      final y = double.parse(parts[1]) + double.parse(parts[3]) / 2;
      await tapAt(x, y);
      break;
    case 'tap':
      await tapAt(double.parse(rest[0]), double.parse(rest[1]));
      break;
    case 'drag':
      await dragAt(double.parse(rest[0]), double.parse(rest[1]), double.parse(rest[2]),
          double.parse(rest[3]), rest.length > 4 ? int.parse(rest[4]) : 12);
      break;
    case 'scroll':
      await scrollAt(double.parse(rest[0]), double.parse(rest[1]), double.parse(rest[2]));
      break;
    case 'text':
      await setText(rest.join(' '));
      break;
    case 'tap-send':
      final found = await findKey('chat-send-stop');
      final parts = found.split(',');
      if (parts.length != 4 || parts[0] == 'not-found') {
        stdout.writeln('not-found:chat-send-stop');
        exit(3);
      }
      await tapAt(double.parse(parts[0]) + double.parse(parts[2]) / 2,
          double.parse(parts[1]) + double.parse(parts[3]) / 2);
      break;
    case 'rect':
      stdout.writeln(await coordsFor(rest[0]));
      break;
    default:
      stderr.writeln('unknown command $command');
      exit(2);
  }
  await service.dispose();
}
