import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/window_mode.dart';

/// t2 回答窗几何 planner 测试（规格 §4.2/§4.3/§5.2）。
void main() {
  const work = Rect.fromLTWH(0, 0, 1920, 1040);
  const input = Rect.fromLTWH(200, 900, 1400, 80);
  const mainWindow = Rect.fromLTWH(100, 100, 1200, 800);

  void expectRect(Rect actual, Rect expected, {double tolerance = 0.6}) {
    expect(actual.left, closeTo(expected.left, tolerance), reason: 'left');
    expect(actual.top, closeTo(expected.top, tolerance), reason: 'top');
    expect(actual.width, closeTo(expected.width, tolerance), reason: 'width');
    expect(actual.height, closeTo(expected.height, tolerance), reason: 'height');
  }

  bool overlaps(Rect a, Rect b) {
    final overlap = a.intersect(b);
    return overlap.width > 0 && overlap.height > 0;
  }

  group('宽度/高度', () {
    test('U-AG-01 宽度 = 35% 钳制 420–900', () {
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 1280, 800)),
          closeTo(448, 0.01));
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 1440, 900)),
          closeTo(504, 0.01));
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 1920, 1040)),
          closeTo(672, 0.01));
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 2560, 1440)),
          closeTo(896, 0.01));
      // 1024×0.35=358.4 -> 420
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 1024, 768)),
          closeTo(420, 0.01));
      // 3440×0.35=1204 -> 900
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 3440, 1440)),
          closeTo(900, 0.01));
      for (final width in <double>[1280, 1920, 2560]) {
        final ratio = AnswerWindowPlanner.widthLogical(
              Rect.fromLTWH(0, 0, width, 1040),
            ) /
            width;
        expect(ratio, inInclusiveRange(0.30, 0.40));
      }
    });

    test('U-AG-02 maxH = min(70%, 760)', () {
      expect(AnswerWindowPlanner.maxHeightLogical(const Rect.fromLTWH(0, 0, 1920, 1040)),
          closeTo(728, 0.01));
      expect(AnswerWindowPlanner.maxHeightLogical(const Rect.fromLTWH(0, 0, 1920, 1080)),
          closeTo(756, 0.01));
      expect(AnswerWindowPlanner.maxHeightLogical(const Rect.fromLTWH(0, 0, 1920, 1440)),
          closeTo(760, 0.01));
      // 极矮工作区仍不返回小于 minH 的上限。
      expect(AnswerWindowPlanner.maxHeightLogical(const Rect.fromLTWH(0, 0, 1920, 200)),
          closeTo(180, 0.01));
    });

    test('U-AG-03 desired = chrome + 正文，钳制 [180, maxH]', () {
      const workLogical = Rect.fromLTWH(0, 0, 1920, 1040);
      expect(
        AnswerWindowPlanner.desiredHeightLogical(0, workLogical: workLogical),
        closeTo(180, 0.01),
      );
      expect(
        AnswerWindowPlanner.desiredHeightLogical(100, workLogical: workLogical),
        closeTo(answerChromeHeight + 100, 0.01),
      );
      expect(
        AnswerWindowPlanner.desiredHeightLogical(5000, workLogical: workLogical),
        closeTo(728, 0.01),
      );
      expect(
        AnswerWindowPlanner.desiredHeightLogical(-50, workLogical: workLogical),
        closeTo(180, 0.01),
      );
    });
  });

  group('auto 放置', () {
    test('U-AG-04 优先输入条上方、右对齐、底边贴 gap', () {
      final rect = AnswerWindowPlanner.place(
        workPhysical: work,
        inputBarPhysical: input,
        mainWindowPhysical: mainWindow,
        dpr: 1.0,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: false,
      );
      expectRect(rect, const Rect.fromLTWH(928, 500, 672, 392));
      expect(overlaps(rect, input), isFalse);
      expect(FloatingWindowPlanner.isInsideWorkArea(rect, work), isTrue);
    });

    test('U-AG-05 输入条靠近顶部 → 放到下方', () {
      const topInput = Rect.fromLTWH(200, 20, 1400, 80);
      final rect = AnswerWindowPlanner.place(
        workPhysical: work,
        inputBarPhysical: topInput,
        mainWindowPhysical: const Rect.fromLTWH(100, 0, 1200, 120),
        dpr: 1.0,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: false,
      );
      expectRect(rect, const Rect.fromLTWH(928, 108, 672, 392));
      expect(overlaps(rect, topInput), isFalse);
    });

    test('U-AG-06 上下空间不足 → 主窗右侧', () {
      const smallWork = Rect.fromLTWH(0, 0, 2560, 800);
      const tallInput = Rect.fromLTWH(100, 100, 1200, 520);
      final rect = AnswerWindowPlanner.place(
        workPhysical: smallWork,
        inputBarPhysical: tallInput,
        mainWindowPhysical: tallInput,
        dpr: 1.0,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: false,
      );
      expectRect(rect, const Rect.fromLTWH(1308, 100, 672, 392));
      expect(overlaps(rect, tallInput), isFalse);
    });

    test('U-AG-07 兜底：最大可用带、高度可小于 minH、不遮挡输入条', () {
      const shortWork = Rect.fromLTWH(0, 0, 1000, 300);
      const middleInput = Rect.fromLTWH(0, 100, 1000, 100);
      final rect = AnswerWindowPlanner.place(
        workPhysical: shortWork,
        inputBarPhysical: middleInput,
        mainWindowPhysical: const Rect.fromLTWH(0, 0, 1000, 300),
        dpr: 1.0,
        widthLogical: 420,
        heightLogical: 392,
        userMoved: false,
      );
      expect(rect.height, lessThan(answerMinHeight));
      expect(overlaps(rect, middleInput), isFalse);
      expect(FloatingWindowPlanner.isInsideWorkArea(rect, shortWork), isTrue);
    });

    test('U-AG-08 DPR 1.5：物理 = 逻辑 × 1.5、工作区正确', () {
      const hidpiWork = Rect.fromLTWH(0, 0, 2880, 1560);
      const hidpiInput = Rect.fromLTWH(300, 1350, 2100, 120);
      final rect = AnswerWindowPlanner.place(
        workPhysical: hidpiWork,
        inputBarPhysical: hidpiInput,
        mainWindowPhysical: const Rect.fromLTWH(150, 150, 1800, 1200),
        dpr: 1.5,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: false,
      );
      expectRect(rect, const Rect.fromLTWH(1392, 750, 1008, 588));
      expect(overlaps(rect, hidpiInput), isFalse);
      expect(FloatingWindowPlanner.isInsideWorkArea(rect, hidpiWork), isTrue);
    });
  });

  group('userMoved', () {
    test('U-AG-09 尊重用户位置（不覆盖输入条时原样保留）', () {
      const userRect = Rect.fromLTWH(1000, 120, 672, 392);
      final rect = AnswerWindowPlanner.place(
        workPhysical: work,
        inputBarPhysical: input,
        mainWindowPhysical: mainWindow,
        dpr: 1.0,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: true,
        userRect: userRect,
      );
      expectRect(rect, userRect);
    });

    test('U-AG-10 覆盖输入条 → 最小位移到上方', () {
      const userRect = Rect.fromLTWH(500, 850, 672, 392);
      final rect = AnswerWindowPlanner.place(
        workPhysical: work,
        inputBarPhysical: input,
        mainWindowPhysical: mainWindow,
        dpr: 1.0,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: true,
        userRect: userRect,
      );
      expect(rect.top + rect.height, lessThanOrEqualTo(input.top));
      expect(overlaps(rect, input), isFalse);
      expectRect(rect, const Rect.fromLTWH(500, 500, 672, 392));
    });

    test('U-AG-11 越界用户位置被钳回工作区', () {
      const outside = Rect.fromLTWH(1800, 1000, 672, 392);
      final rect = AnswerWindowPlanner.place(
        workPhysical: work,
        inputBarPhysical: input,
        mainWindowPhysical: mainWindow,
        dpr: 1.0,
        widthLogical: 672,
        heightLogical: 392,
        userMoved: true,
        userRect: outside,
      );
      expect(FloatingWindowPlanner.isInsideWorkArea(rect, work), isTrue);
      expect(rect.right, lessThanOrEqualTo(work.right + 0.5));
      expect(rect.bottom, lessThanOrEqualTo(work.bottom + 0.5));
    });
  });

  test('U-AG-12 overlapsInputBar 含 gap 判定', () {
    const answer = Rect.fromLTWH(0, 0, 100, 100);
    // 输入条顶边 105，answer 底边 100；gap=8 → 排除区顶边 97 与 answer 相交。
    const nearBar = Rect.fromLTWH(0, 105, 100, 20);
    expect(
      AnswerWindowPlanner.overlapsInputBar(
        answerPhysical: answer,
        inputBarPhysical: nearBar,
        dpr: 1.0,
      ),
      isTrue,
    );
    // 输入条顶边 110；gap=8 → 排除区顶边 102，不相交。
    const farBar = Rect.fromLTWH(0, 110, 100, 20);
    expect(
      AnswerWindowPlanner.overlapsInputBar(
        answerPhysical: answer,
        inputBarPhysical: farBar,
        dpr: 1.0,
      ),
      isFalse,
    );
  });
}
