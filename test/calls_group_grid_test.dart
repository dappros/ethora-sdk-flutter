import 'package:ethora_sdk_flutter/src/ui/calls/group_grid_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The stage of a phone in portrait / landscape, minus the title and
  // control bars.
  const portraitW = 400.0;
  const portraitH = 640.0;

  test('one participant fills the stage', () {
    final plan = planGroupGrid(1, portraitW, portraitH);
    expect((plan.columns, plan.rows), (1, 1));
    expect(plan.scrolls, isFalse);
  });

  test('two stack vertically on a portrait phone, side by side in landscape',
      () {
    final portrait = planGroupGrid(2, portraitW, portraitH);
    expect((portrait.columns, portrait.rows), (1, 2));
    final landscape = planGroupGrid(2, 800, 330);
    expect((landscape.columns, landscape.rows), (2, 1));
  });

  test('three and four use a 2 column grid; five and six three rows', () {
    expect(planGroupGrid(3, portraitW, portraitH).columns, 2);
    final four = planGroupGrid(4, portraitW, portraitH);
    expect((four.columns, four.rows), (2, 2));
    final six = planGroupGrid(6, portraitW, portraitH);
    expect((six.columns, six.rows), (2, 3));
    expect(six.scrolls, isFalse);
  });

  test('tiles keep a sensible shape', () {
    for (var n = 1; n <= 9; n++) {
      final plan = planGroupGrid(n, portraitW, portraitH);
      expect(plan.aspectRatio, inInclusiveRange(0.5, 2.0), reason: 'n=$n');
      expect(plan.columns * plan.rows, greaterThanOrEqualTo(n));
    }
  });

  test('a crowd scrolls with square tiles instead of unrecognisable ones', () {
    final plan = planGroupGrid(30, portraitW, portraitH);
    expect(plan.scrolls, isTrue);
    expect(plan.aspectRatio, 1);
    expect(plan.columns, 3);
    expect(plan.columns * plan.rows, greaterThanOrEqualTo(30));
    expect(planGroupGrid(30, 900, 500).columns, 4);
    expect(planGroupGrid(30, 320, 500).columns, 2);
  });

  test('degenerate sizes never throw', () {
    expect(planGroupGrid(0, 400, 600).columns, 1);
    expect(planGroupGrid(3, 0, 0).scrolls, isTrue);
    expect(planGroupGrid(3, 10, 10).columns, greaterThan(0));
  });
}
