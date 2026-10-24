// t4 floating VM-service probe: logical viewport, DPR, ChatScreenState identity.
// Usage: dart run bin/vm_probe.dart "ws://127.0.0.1:PORT/token=/ws" [label]
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<InstanceRef?> eval(VmService service, String isolateId, String targetId, String expression) async {
  final response = await service.evaluate(isolateId, targetId, expression);
  return InstanceRef.parse(response.json!);
}

Future<Map<String, Object?>> evalMap(
    VmService service, String isolateId, String targetId, Map<String, String> expressions) async {
  final out = <String, Object?>{};
  for (final entry in expressions.entries) {
    try {
      final ref = await eval(service, isolateId, targetId, entry.value);
      out[entry.key] = ref?.valueAsString ?? '<no value>';
    } catch (error) {
      out[entry.key] = '<error: $error>';
    }
  }
  return out;
}

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: vm_probe.dart <ws-uri> [label]');
    exit(2);
  }
  final label = args.length > 1 ? args[1] : '';
  final service = await vmServiceConnectUri(args[0]);
  final vm = await service.getVM();
  final isolateRef = vm.isolates!.firstWhere(
    (iso) => iso.name == 'main' || (iso.name?.contains('main') ?? false),
    orElse: () => vm.isolates!.first,
  );
  final isolateId = isolateRef.id!;
  final isolate = await service.getIsolate(isolateId);
  final rootLib = isolate.rootLib!.id!;

  final views = await evalMap(service, isolateId, rootLib, {
    'dpr': 'WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio',
    'physicalWidth': 'WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width',
    'physicalHeight': 'WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.height',
    'logicalWidth': '(WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width / '
        'WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio)',
    'logicalHeight': '(WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.height / '
        'WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio)',
    'views': 'WidgetsBinding.instance.platformDispatcher.views.length',
    'mode': 'WindowController.instance.floating.mode.name',
    'pinned': 'WindowController.instance.floating.pinned',
    'transitioning': 'WindowController.instance.floating.transitioning',
    'captureInProgress': 'WindowController.instance.floating.captureInProgress',
    'windowReady': 'WindowController.instance.ready',
    'hotkeyToggle': 'HotkeyService.instance.status.value.toggleConflict',
    'hotkeyScreenshot': 'HotkeyService.instance.status.value.screenshotConflict',
  }).catchError((Object error) => <String, Object?>{'error': '$error'});
  // rootLib 里没有 import window_controls 时，退回 appState 所在库逐个探测。
  final chatStates = <Map<String, Object?>>[];
  final classes = await service.getClassList(isolateId);
  for (final cls in classes.classes ?? <ClassRef>[]) {
    if (cls.name == 'ChatScreenState' && cls.id != null) {
      final instances = await service.getInstances(isolateId, cls.id!, 10);
      for (final ref in instances.instances ?? <ObjRef>[]) {
        final id = ref.id;
        if (id == null) continue;
        final fields = await evalMap(service, isolateId, id, {
          'id': 'this',
          'conversationId': 'conversationId',
          'messageCount': 'messageCount',
          'attachmentCount': 'attachmentCount',
          'isSending': 'isSending',
          'isGenerating': 'isGenerating',
          'runId': 'runId',
          'approvalVisible': 'approvalVisible',
          'floating': 'widget.floating',
          'compact': 'widget.compact',
          'active': 'widget.active',
        });
        fields['identityHashCode'] = ref is InstanceRef ? ref.identityHashCode : null;
        fields['objectId'] = id;
        chatStates.add(fields);
      }
    }
  }

  final shellStates = <Map<String, Object?>>[];
  for (final cls in classes.classes ?? <ClassRef>[]) {
    if (cls.name == '_ShellState' && cls.id != null) {
      final instances = await service.getInstances(isolateId, cls.id!, 10);
      for (final ref in instances.instances ?? <ObjRef>[]) {
        final id = ref.id;
        if (id == null) continue;
        final fields = await evalMap(service, isolateId, id, {
          'id': 'this',
          'index': '_index',
          'wasFloating': '_wasFloating',
          'indexBeforeFloating': '_indexBeforeFloating',
        });
        fields['identityHashCode'] = ref is InstanceRef ? ref.identityHashCode : null;
        fields['objectId'] = id;
        shellStates.add(fields);
      }
    }
  }

  final result = {
    'label': label,
    'isolate': isolateRef.name,
    'views': views,
    'chatStateCount': chatStates.length,
    'chatStates': chatStates,
    'shellStateCount': shellStates.length,
    'shellStates': shellStates,
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  await service.dispose();
}
