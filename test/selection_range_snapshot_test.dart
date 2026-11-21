import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/common/selection_range_snapshot.dart';

void main() {
  test('an active range cannot select replacement rows at its old indexes', () {
    final range = SelectionRangeSnapshot();
    const first = (anchor: 0, previous: 0, current: 0, checked: true);
    const sweep = (anchor: 0, previous: 0, current: 2, checked: true);
    const visible = ['a', 'b', 'c'];
    const reordered = ['c', 'a', 'b'];
    expect(range.apply(first, visible, {}), {'a'});
    expect(range.apply(sweep, reordered, {'a'}), isNull);
    // Returning to the same order does not resume the invalidated gesture.
    expect(range.apply(sweep, visible, {'a'}), isNull);
    // A new gesture takes a fresh snapshot from the new anchor.
    expect(range.apply(first, reordered, {'a'}), {'a', 'c'});
  });
}
