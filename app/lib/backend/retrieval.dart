import 'dart:convert';

import 'db.dart';

final _cjk = RegExp(r'[\u4e00-\u9fff]+');
final _word = RegExp(r'[A-Za-z][A-Za-z0-9_+\-]+');

/// 中文按二字切分，英文按词，配合 FTS5 做 BM25 检索。
List<String> tokenize(String text, {int limit = 300}) {
  final out = <String>[];
  for (final run in _cjk.allMatches(text)) {
    final value = run.group(0)!;
    if (value.length == 1) {
      out.add(value);
    } else {
      for (var i = 0; i < value.length - 1; i++) {
        out.add(value.substring(i, i + 2));
      }
    }
  }
  for (final match in _word.allMatches(text)) {
    out.add(match.group(0)!.toLowerCase());
  }
  final seen = <String>{};
  final result = <String>[];
  for (final token in out) {
    if (seen.add(token)) result.add(token);
    if (result.length >= limit) break;
  }
  return result;
}

List<(int, String)> chunkPages(List<String> pages, {int size = 800, int overlap = 100}) {
  final chunks = <(int, String)>[];
  for (var i = 0; i < pages.length; i++) {
    final text = pages[i].replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) continue;
    var start = 0;
    while (start < text.length) {
      var end = start + size;
      if (end > text.length) end = text.length;
      if (end < text.length) {
        final floor = start + (size ~/ 2 > 200 ? size ~/ 2 : 200);
        for (final sep in ['。', '！', '？', '；', '. ', '，', ',', ' ']) {
          final pos = text.lastIndexOf(sep, end);
          if (pos >= floor) {
            end = pos + sep.length;
            break;
          }
        }
      }
      final piece = text.substring(start, end).trim();
      if (piece.length >= 4) chunks.add((i + 1, piece));
      if (end >= text.length) break;
      start = end - overlap > start ? end - overlap : start + 1;
    }
  }
  return chunks;
}

int indexMaterial(int materialId, List<String> pages) {
  removeMaterialIndex(materialId);
  var count = 0;
  for (final (page, text) in chunkPages(pages)) {
    final chunkId = Db.insert('chunks', {
      'material_id': materialId,
      'page': page,
      'text': text,
    });
    Db.run('INSERT INTO chunks_fts(chunk_id, tokens) VALUES(?, ?)', [
      chunkId,
      tokenize(text).join(' '),
    ]);
    count++;
  }
  return count;
}

void removeMaterialIndex(int materialId) {
  Db.run(
    'DELETE FROM chunks_fts WHERE chunk_id IN (SELECT id FROM chunks WHERE material_id=?)',
    [materialId],
  );
  Db.run('DELETE FROM chunks WHERE material_id=?', [materialId]);
}

List<Map<String, Object?>> search(String query, {int limit = 5}) {
  final tokens = tokenize(query);
  if (tokens.isEmpty) return [];
  final match = tokens.take(24).map((t) => '"$t"').join(' OR ');
  try {
    return Db.rows('''
      SELECT c.id, c.material_id, c.page, c.text, m.name AS material_name,
             bm25(chunks_fts) AS score
      FROM chunks_fts
      JOIN chunks c ON c.id = chunks_fts.chunk_id
      JOIN materials m ON m.id = c.material_id
      WHERE chunks_fts MATCH ?
      ORDER BY score LIMIT ?
    ''', [match, limit]);
  } catch (_) {
    return [];
  }
}

(String, List<Map<String, Object?>>) formatSnippets(
  List<Map<String, Object?>> hits, {
  int budget = 2400,
}) {
  final parts = <String>[];
  final refs = <Map<String, Object?>>[];
  var used = 0;
  for (final hit in hits) {
    final text = (hit['text'] ?? '').toString().trim();
    if (text.isEmpty) continue;
    final block = '[${hit['material_name']} p.${hit['page']}]\n$text';
    if (used + block.length > budget) break;
    used += block.length;
    parts.add(block);
    refs.add({
      'material_id': hit['material_id'],
      'name': hit['material_name'],
      'page': hit['page'],
      'snippet': text.length > 160 ? text.substring(0, 160) : text,
    });
  }
  return (parts.join('\n\n'), refs);
}

String encodeJson(Object? value) => jsonEncode(value);
