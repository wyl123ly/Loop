import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/models.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/markdown_text.dart';

void main() {
  test('Message 解析 steps 和 refs', () {
    final message = Message.fromJson({
      'id': 7,
      'role': 'assistant',
      'content': '特征值……',
      'steps': [
        {'name': 'search_materials', 'status': 'done', 'detail': '命中 3 段'}
      ],
      'refs': [
        {'name': '线代讲义.pdf', 'page': 12}
      ],
      'tokens_in': 100,
      'tokens_out': 50,
    });
    expect(message.id, 7);
    expect(message.content, contains('特征值'));
    expect(message.steps.single.label, '检索资料');
    expect(message.refs.single.page, 12);
  });

  test('ToolStep label 映射', () {
    expect(ToolStep(name: 'create_tasks', status: 'done').label, '创建待办');
    expect(ToolStep(name: 'plan_exam', status: 'done').label, '排学习计划');
  });

  test('Conversation 解析', () {
    final conversation = Conversation.fromJson({
      'id': 3,
      'title': '特征值是什么',
      'preview': '特征值刻画方向不变',
      'messages': 4,
      'updated_at': '2026-10-22T20:00:00+08:00',
    });
    expect(conversation.id, 3);
    expect(conversation.title, '特征值是什么');
    expect(conversation.messages, 4);
  });

  test('TodayData 解析待办', () {
    final today = TodayData.fromJson({
      'date': '2026-10-22',
      'tasks': [
        {'id': 1, 'title': '线代 3.2', 'due': '2026-10-22', 'status': 'todo', 'estimate_min': 45}
      ],
      'done_today': 2,
      'open_total': 5,
      'overdue': 1,
    });
    expect(today.tasks.single.estimateMin, 45);
    expect(today.doneToday, 2);
    expect(today.overdue, 1);
    expect(today.openTotal, 5);
  });


  test('计划写步骤自动完成与未完成收尾', () {
    final plan = PlanState();
    plan.apply([
      {'id': '1', 'title': '检索资料', 'status': 'done'},
      {'id': '2', 'title': '写测试笔记', 'status': 'in_progress'},
      {'id': '3', 'title': '回读核对', 'status': 'pending'},
    ]);
    expect(plan.completeActiveWrite(), isTrue);
    expect(plan.items[1].status, 'done');
    expect(plan.finalizeIncomplete(), isTrue);
    expect(plan.items.where((item) => item.status == 'in_progress'), isEmpty);
    expect(plan.items[2].status, 'skipped');
  });

  testWidgets('深色主题行内代码使用主题标签色', (tester) async {
    LoopTheme.palette = LoopPalette.dark;
    addTearDown(() => LoopTheme.palette = LoopPalette.light);
    await tester.pumpWidget(MaterialApp(
      theme: loopTheme(LoopPalette.dark),
      home: const Scaffold(body: MarkdownText('关键词 `矩阵的秩` 结束')),
    ));
    final code = find.text('矩阵的秩');
    expect(code, findsOneWidget);
    final text = tester.widget<Text>(code);
    expect(text.style?.color, LoopPalette.dark.codeFg);
    final container = tester.widget<Container>(
      find.ancestor(of: code, matching: find.byType(Container)).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, LoopPalette.dark.codeBg);
    expect(decoration.color, isNot(LoopPalette.dark.danger));
  });

}
