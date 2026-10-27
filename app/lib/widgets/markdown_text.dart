import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../theme.dart';

/// 轻量 Markdown 渲染：标题 / 列表 / 引用 / 表格 / 代码块 / 行内公式。
/// 没有引第三方 markdown 包，是为了把 $...$ 公式和中文排版控制在自己手里。
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.data, {super.key, this.baseStyle});

  final String data;
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final style = baseStyle ?? Theme.of(context).textTheme.bodyMedium!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _parse(context, data, style),
    );
  }

  List<Widget> _parse(BuildContext context, String text, TextStyle style) {
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final widgets = <Widget>[];
    var i = 0;

    while (i < lines.length) {
      final raw = lines[i];
      final line = raw.trimRight();
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      // ``` 代码块
      if (trimmed.startsWith('```')) {
        final buffer = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          buffer.add(lines[i]);
          i++;
        }
        i++;
        widgets.add(_codeBlock(buffer.join('\n')));
        continue;
      }

      // $$ 块级公式
      if (trimmed.startsWith(r'$$')) {
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          widgets.add(_blockMath(trimmed.substring(2, trimmed.length - 2), style));
          i++;
          continue;
        }
        final buffer = <String>[trimmed.substring(2)];
        i++;
        while (i < lines.length && !lines[i].trim().endsWith(r'$$')) {
          buffer.add(lines[i]);
          i++;
        }
        if (i < lines.length) {
          final last = lines[i].trim();
          buffer.add(last.substring(0, last.length - 2));
          i++;
        }
        widgets.add(_blockMath(buffer.join('\n'), style));
        continue;
      }

      // 分割线
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        widgets.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1),
        ));
        i++;
        continue;
      }

      // 标题
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final content = heading.group(2)!;
        final size = switch (level) { 1 => 20.0, 2 => 17.5, 3 => 16.0, _ => 15.0 };
        widgets.add(Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 16, bottom: 8),
          child: Text.rich(
            TextSpan(
              children: _inline(context, content, style),
              style: style.copyWith(fontSize: size, fontWeight: FontWeight.w700, height: 1.4),
            ),
          ),
        ));
        i++;
        continue;
      }

      // 表格
      if (trimmed.contains('|') &&
          i + 1 < lines.length &&
          RegExp(r'^\s*\|?[\s:\-|]+\|?\s*$').hasMatch(lines[i + 1]) &&
          lines[i + 1].contains('-')) {
        final table = <List<String>>[];
        var header = _cells(trimmed);
        i += 2;
        while (i < lines.length && lines[i].trim().isNotEmpty && lines[i].contains('|')) {
          table.add(_cells(lines[i].trim()));
          i++;
        }
        widgets.add(_table(context, header, table, style));
        continue;
      }

      // 引用
      if (trimmed.startsWith('>')) {
        final buffer = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          buffer.add(lines[i].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          i++;
        }
        widgets.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: pal.accent, width: 3)),
            color: pal.chip,
          ),
          child: Text.rich(TextSpan(
            children: _inline(context, buffer.join('\n'), style),
            style: style.copyWith(color: pal.muted),
          )),
        ));
        continue;
      }

      // 无序列表
      final bullet = RegExp(r'^([-*•])\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        widgets.add(_listRow(context, '•', bullet.group(2)!, style, i));
        i++;
        continue;
      }

      // 有序列表
      final ordered = RegExp(r'^(\d{1,2})[.)]\s+(.*)$').firstMatch(trimmed);
      if (ordered != null) {
        widgets.add(_listRow(context, '${ordered.group(1)}.', ordered.group(2)!, style, i));
        i++;
        continue;
      }

      // 普通段落（连续行合并，保留换行）
      final buffer = <String>[trimmed];
      i++;
      while (i < lines.length) {
        final next = lines[i].trim();
        if (next.isEmpty ||
            next.startsWith('#') ||
            next.startsWith('>') ||
            next.startsWith('```') ||
            RegExp(r'^([-*•]|\d{1,2}[.)])\s+').hasMatch(next) ||
            RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(next) ||
            next.startsWith(r'$$')) {
          break;
        }
        buffer.add(next);
        i++;
      }
      widgets.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text.rich(
          TextSpan(children: _inline(context, buffer.join('\n'), style), style: style),
        ),
      ));
    }
    return widgets;
  }

  List<String> _cells(String line) {
    var value = line.trim();
    if (value.startsWith('|')) value = value.substring(1);
    if (value.endsWith('|')) value = value.substring(0, value.length - 1);
    return value.split('|').map((cell) => cell.trim()).toList();
  }

  Widget _table(BuildContext context, List<String> header, List<List<String>> rows, TextStyle style) {
    final columns = header.length.clamp(1, 6);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄窗（360 浮窗）下给表格最小可读宽度并允许横向滚动，
          // 宽窗下宽度与可用宽度一致（保持 v0.4.0 的观感）。
          final available =
              constraints.maxWidth.isFinite ? constraints.maxWidth : 640.0;
          final minimum = columns * 96.0;
          final tableWidth = available > minimum ? available : minimum;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(LoopRadius.control),
                child: Table(
                  border: TableBorder.all(color: pal.border, width: 1),
                  defaultColumnWidth: const FlexColumnWidth(),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: pal.chip),
                      children: List.generate(columns, (index) {
                        final text = index < header.length ? header[index] : '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Text.rich(TextSpan(
                            children: _inline(context, text, style),
                            style: style.copyWith(fontWeight: FontWeight.w600, fontSize: LoopType.body),
                          )),
                        );
                      }),
                    ),
                    for (final row in rows)
                      TableRow(
                        children: List.generate(columns, (index) {
                          final text = index < row.length ? row[index] : '';
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Text.rich(TextSpan(
                              children: _inline(context, text, style),
                              style: style.copyWith(fontSize: LoopType.body),
                            )),
                          );
                        }),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _listRow(BuildContext context, String marker, String content, TextStyle style, int index) {
    return Padding(
      padding: EdgeInsets.only(top: index == 0 ? 4 : 4, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: marker == '•' ? 18 : 26,
            child: Text(marker, style: style.copyWith(color: pal.muted, height: 1.65)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(children: _inline(context, content, style), style: style),
            ),
          ),
        ],
      ),
    );
  }

  Widget _codeBlock(String code) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pal.codeBg,
        borderRadius: BorderRadius.circular(LoopRadius.control),
        border: Border.all(color: pal.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SelectableText(
          code,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: LoopType.secondary,
            height: 1.55,
            color: pal.ink,
          ),
        ),
      ),
    );
  }

  Widget _blockMath(String tex, TextStyle style) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      // 宽公式在 360 浮窗里允许横向滚动，避免撑破气泡。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Math.tex(
          tex.trim(),
          mathStyle: MathStyle.display,
          textStyle: style.copyWith(fontSize: LoopType.title),
          onErrorFallback: (error) => Text(
            '\$\$${tex.trim()}\$\$',
            style: style.copyWith(fontFamily: 'monospace', color: pal.muted),
          ),
        ),
      ),
    );
  }

  InlineSpan _inlineCode(String text) {
    final ascii = RegExp(r'^[\x20-\x7E]+$').hasMatch(text);
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: pal.codeBg,
          borderRadius: BorderRadius.circular(LoopRadius.small),
          border: Border.all(color: pal.accent.withValues(alpha: 0.22), width: 0.8),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: ascii ? 'monospace' : 'NotoSC',
            fontSize: LoopType.secondary,
            height: 1.35,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
            color: pal.codeFg,
          ),
        ),
      ),
    );
  }

  List<InlineSpan> _inline(BuildContext context, String text, TextStyle style) {
    // 模型有时会把公式写成 \$...\$（Markdown 转义），这里把成对转义还原成公式。
    text = text.replaceAllMapped(
      RegExp(r'\\\$([^$\n]+?)\\\$'),
      (match) => '\$${match[1]}\$',
    );
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'(\*\*.+?\*\*|__.+?__|`[^`\n]+`|\$[^$\n]+\$|(?<!\*)\*[^*\n]+\*(?!\*)|\[[^\]]+\]\([^)]+\))',
      multiLine: true,
    );
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**') || token.startsWith('__')) {
        final inner = token.substring(2, token.length - 2);
        final boldStyle = style.copyWith(fontWeight: FontWeight.w700);
        spans.add(TextSpan(
          style: boldStyle,
          children: _inline(context, inner, boldStyle),
        ));
      } else if (token.startsWith('`')) {
        spans.add(_inlineCode(token.substring(1, token.length - 1)));
      } else if (token.startsWith(r'$')) {
        final tex = token.substring(1, token.length - 1);
        if (_validTex(tex)) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Math.tex(
              tex,
              mathStyle: MathStyle.text,
              textStyle: style.copyWith(fontSize: (style.fontSize ?? 14.5) * 0.98),
              onErrorFallback: (error) => Text('\$$tex\$', style: style),
            ),
          ));
        } else {
          spans.add(TextSpan(text: token));
        }
      } else if (token.startsWith('[')) {
        final label = token.substring(1, token.indexOf(']'));
        final linkStyle = TextStyle(color: pal.accent, decoration: TextDecoration.underline);
        spans.add(TextSpan(
          style: linkStyle,
          children: _inline(context, label, linkStyle),
        ));
      } else {
        final inner = token.substring(1, token.length - 1);
        final italicStyle = style.copyWith(fontStyle: FontStyle.italic);
        spans.add(TextSpan(
          style: italicStyle,
          children: _inline(context, inner, italicStyle),
        ));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: text));
    return spans;
  }

  bool _validTex(String tex) {
    if (tex.trim().isEmpty || tex.length > 300) return false;
    var depth = 0;
    for (final code in tex.codeUnits) {
      if (code == 0x7B) depth++;
      if (code == 0x7D) depth--;
      if (depth < 0) return false;
    }
    return depth == 0;
  }
}
