// How a group call lays its participant tiles out: as many columns as make the
// tiles biggest without squashing them, and a scrolling grid once the tiles
// would be too small to recognise anyone.

import 'dart:math';

class GroupGridPlan {
  const GroupGridPlan({
    required this.columns,
    required this.rows,
    required this.aspectRatio,
    required this.scrolls,
  });

  final int columns;
  final int rows;

  /// Width over height of one tile.
  final double aspectRatio;

  /// More tiles than fit: the grid scrolls vertically.
  final bool scrolls;
}

/// Tiles smaller than this (in logical pixels, per side) are not worth
/// squeezing in: the grid scrolls instead.
const double kMinGroupTileSide = 110;

/// Picks the column count for [count] tiles in a [width] x [height] area.
///
/// A candidate must keep tiles between 0.55 and 1.5 in aspect ratio (neither
/// slivers nor strips); the winner has the largest tile area, fewer columns on
/// a tie. If even the winner's tiles are under [kMinGroupTileSide] on a side,
/// the grid scrolls with square tiles instead.
GroupGridPlan planGroupGrid(
  int count,
  double width,
  double height, {
  double gap = 4,
}) {
  final n = max(1, count);
  GroupGridPlan? best;
  var bestArea = 0.0;
  for (var columns = 1; columns <= min(n, 5); columns++) {
    final rows = (n / columns).ceil();
    final tileW = (width - gap * (columns - 1)) / columns;
    final tileH = (height - gap * (rows - 1)) / rows;
    if (tileW <= 0 || tileH <= 0) continue;
    final aspect = tileW / tileH;
    if (aspect < 0.55 || aspect > 1.5) continue;
    final area = tileW * tileH;
    if (area > bestArea + 0.5) {
      bestArea = area;
      best = GroupGridPlan(
        columns: columns,
        rows: rows,
        aspectRatio: aspect,
        scrolls: false,
      );
    }
  }
  if (best != null) {
    final side = sqrt(bestArea);
    final tileW = (width - gap * (best.columns - 1)) / best.columns;
    final tileH = (height - gap * (best.rows - 1)) / best.rows;
    if (min(tileW, tileH) >= kMinGroupTileSide ||
        side >= kMinGroupTileSide * 1.4) {
      return best;
    }
  }
  final columns = width >= 600 ? 4 : (width >= 340 ? 3 : 2);
  return GroupGridPlan(
    columns: columns,
    rows: (n / columns).ceil(),
    aspectRatio: 1,
    scrolls: true,
  );
}
