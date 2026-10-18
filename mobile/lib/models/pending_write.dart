/// One write the app still owes the database (offline-first
/// Phase 5, Option A, commit 2). See `OFFLINE_SYNC_PLAN.md`
/// for the contract this type carries.
///
/// The payload is **the SQL the failed write would have run**,
/// not a re-encoding of the model: each repository already
/// renders its write with the last-write-wins guard baked into
/// the statement (the trip upsert's `WHERE trips.updated_at =
/// …`), so replay is byte-identical to the write that could
/// not be sent. There is no second serializer to drift, and
/// "nothing may replay that the current guard would refuse"
/// holds by construction.
library;

class PendingWrite {
  /// The whole value this write replaces: `trip:<id>`,
  /// `destination:<name>` or `open_tabs`. A newer op with
  /// the same key supersedes an older one -- replaying the
  /// older value first would only be overwritten.
  final String key;

  /// What the sync-state line calls it ("trip “Japan”").
  final String label;

  /// The statements, in order.
  final List<String> statements;

  /// True when `statements.first` is the guard-bearing
  /// upsert: it runs alone, and a zero affected-row count
  /// means another device got there first (a conflict), so
  /// the rest must **not** run -- exactly the order the
  /// online save uses.
  final bool guardFirst;

  /// When the op was queued (minute precision stamp).
  final String at;

  const PendingWrite({
    required this.key,
    required this.label,
    required this.statements,
    this.guardFirst = false,
    required this.at,
  });

  Map<String, Object?> toJson() => {
        'key': key,
        'label': label,
        'guard_first': guardFirst,
        'at': at,
        'statements': statements,
      };

  /// Null on any wrong shape: a corrupt journal line is
  /// *dropped*, never guessed at.
  static PendingWrite? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) return null;
    final key = value['key'];
    final label = value['label'];
    final at = value['at'];
    final statements = value['statements'];
    if (key is! String || key.isEmpty) return null;
    if (label is! String) return null;
    if (at is! String) return null;
    if (statements is! List) return null;
    return PendingWrite(
      key: key,
      label: label,
      at: at,
      guardFirst: value['guard_first'] == true,
      statements: [
        for (final statement in statements)
          if (statement is String && statement.trim().isNotEmpty) statement,
      ],
    );
  }
}
