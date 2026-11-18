/// Evidence recorded after checking the purchasing account and complete media.
/// Absence of a local deadline alone is never an authorization.
enum CourseCacheExpiryKind {
  legacyReceipt,
  serverDeadline,
  explicitLongTerm,
  noDeclaredDeadline;

  bool accepts(DateTime? checkedAt, DateTime? until) {
    if (checkedAt == null || checkedAt.millisecondsSinceEpoch <= 0) {
      return false;
    }
    return switch (this) {
      legacyReceipt =>
        until != null &&
            until.isAfter(checkedAt) &&
            // The old on-disk format could not distinguish this app's window
            // from a provider limit. Never promote it without rechecking.
            until.difference(checkedAt) <= const Duration(hours: 24),
      serverDeadline => until != null && until.isAfter(checkedAt),
      explicitLongTerm || noDeclaredDeadline => until == null,
    };
  }

  bool usableAt(DateTime now, DateTime? checkedAt, DateTime? until) =>
      accepts(checkedAt, until) &&
      !now.isBefore(checkedAt!) &&
      (until == null || now.isBefore(until));
}
