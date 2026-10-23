import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/markdown_text.dart';

Future<List<String>> pumpText(WidgetTester tester, String markdown) async {
  LoopTheme.palette = LoopPalette.light;
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(body: SingleChildScrollView(child: MarkdownText(markdown))),
  ));
  final texts = <String>[];
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    texts.add(rich.text.toPlainText());
  }
  return texts;
}

void main() {
  testWidgets('inline math plain dollars', (tester) async {
    await pumpText(tester, r'是 $r(A)$ = $A$ 中');
    expect(find.byType(Math), findsNWidgets(2));
  });

  testWidgets('inline math escaped dollars', (tester) async {
    final texts = await pumpText(tester, r'是 \$r(A)\$ = \$A\$ 中');
    expect(find.byType(Math), findsNWidgets(2));
    expect(texts.any((text) => text.contains(r'\$')), isFalse);
  });

  testWidgets('inline math inside bold', (tester) async {
    final texts = await pumpText(tester, r'**$r(A)$ = $A$ 中最高阶非零子式**');
    expect(find.byType(Math), findsNWidgets(2));
    expect(texts.any((text) => text.contains(r'$r(A)$')), isFalse);
  });

  testWidgets('math inside italic and table cell', (tester) async {
    await pumpText(tester, '| 结论 |\n|---|\n| *\$r(A)\$* |');
    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('math inside code stays literal', (tester) async {
    await pumpText(tester, r'`$r(A)$`');
    expect(find.byType(Math), findsNothing);
  });

  testWidgets('inline math with relation', (tester) async {
    await pumpText(tester, r'于是 $r(A) = r(A^{\mathrm T})$ 成立');
    expect(find.byType(Math), findsWidgets);
  });
}
