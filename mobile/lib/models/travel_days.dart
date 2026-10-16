/// Free-form travel-day selection: which days count as "out
/// on" and "back on", and the time bound each day carries.
///
/// Replaces the fixed Thu/Fri/Sat vs Sat/Sun/Mon/Tue slots
/// (report b, 2026-10-16). The user picks a travel *period*
/// on a calendar; the candidate days are the period plus the
/// day before and the day after (the flex days); each
/// candidate day is selected or deselected per side, and
/// each selected day gets a bound: any time, after a time
/// (out: departure, back: landing) or before it.
///
/// The legacy defaults survive as the "this weekend" preset
/// -- out Fri from 14:00 and Sat before 12:00, back Sun any
/// time and Mon before 09:00 -- so the finder answers the
/// classic question exactly as before until the days are
/// touched.
///
/// Pure Dart: no Flutter, no Turso. Times are naive
/// wall-clock minutes-of-day, the same convention the board
/// parser keeps.
library;

/// How a day's time bound reads. [DayBound.any] is a full
/// day; [DayBound.after] and [DayBound.before] narrow it.
enum DayBound { any, after, before }

/// One selected day and its bound.
class TravelDay {
  /// The calendar day (time-of-day is ignored).
  final DateTime day;

  final DayBound bound;

  /// Minutes-of-day for [DayBound.after]/[DayBound.before];
  /// null for [DayBound.any].
  final int? minutes;

  const TravelDay(this.day, {this.bound = DayBound.any, this.minutes});

  /// The same day with another bound.
  TravelDay withBound(DayBound bound, int? minutes) =>
      TravelDay(day, bound: bound, minutes: minutes);

  /// Whether a flight at `minutesOfDay` fits this day.
  ///
  /// "after" is inclusive (>=, the legacy's Friday rule),
  /// "before" is strict (<, the legacy's Saturday rule).
  bool accepts(int minutesOfDay) {
    switch (bound) {
      case DayBound.any:
        return true;
      case DayBound.after:
        return minutes != null && minutesOfDay >= minutes!;
      case DayBound.before:
        return minutes != null && minutesOfDay < minutes!;
    }
  }

  /// The board window this day needs: the whole day for
  /// "any"/"after", the morning part for "before". The
  /// matcher applies the same bound again -- the window is
  /// only how far the board is walked.
  (DateTime, DateTime) fetchWindow() {
    final startOfDay = DateTime(day.year, day.month, day.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    switch (bound) {
      case DayBound.any:
        return (startOfDay, endOfDay);
      case DayBound.after:
        return (startOfDay.add(Duration(minutes: minutes!)), endOfDay);
      case DayBound.before:
        return (startOfDay, startOfDay.add(Duration(minutes: minutes!)));
    }
  }

  /// "departs after 14:00" / "lands before 09:00" / "any
  /// time" -- the bound named with the clock it applies to
  /// (a bare "before" is ambiguous: leaving before noon and
  /// landing before noon are different days).
  String describe({required bool outbound}) {
    final verb = outbound ? 'departs' : 'lands';
    switch (bound) {
      case DayBound.any:
        return 'any time';
      case DayBound.after:
        return '$verb after ${TravelDay._hm(minutes!)}';
      case DayBound.before:
        return '$verb before ${TravelDay._hm(minutes!)}';
    }
  }

  static String _hm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  /// Days sort chronologically.
  int compareTo(TravelDay other) => day.compareTo(other.day);
}

/// The whole selection one search runs with.
class TravelPlan {
  /// Departure days that count, and their bounds.
  final List<TravelDay> outDays;

  /// Landing days that count, and their bounds.
  final List<TravelDay> backDays;

  /// What the period is called in the report ("this
  /// weekend", "10 Dec – 15 Dec").
  final String label;

  const TravelPlan({
    required this.outDays,
    required this.backDays,
    this.label = '',
  });

  bool get hasOut => outDays.isNotEmpty;
  bool get hasBack => backDays.isNotEmpty;

  /// The one-line rule summary the finder card shows.
  String describe() {
    final out = [
      for (final day in _sorted(outDays))
        '${_short(day.day)} ${day.describe(outbound: true)}',
    ];
    final back = [
      for (final day in _sorted(backDays))
        '${_short(day.day)} ${day.describe(outbound: false)}',
    ];
    return 'out: ${out.join(', ')} · back: ${back.join(', ')}';
  }

  static List<TravelDay> _sorted(List<TravelDay> days) =>
      [...days]..sort((a, b) => a.compareTo(b));

  static String _short(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
}

/// The travel period the calendar picker returns: the span
/// the user considers travel.
class TravelPeriod {
  final DateTime start;
  final DateTime end;

  const TravelPeriod(this.start, this.end);

  /// The period's own days.
  Iterable<DateTime> get days sync* {
    for (var day = _date(start);
        !day.isAfter(_date(end));
        day = day.add(const Duration(days: 1))) {
      yield day;
    }
  }

  String describe() => '${_d(start)} – ${_d(end)}';

  static String _d(DateTime day) =>
      '${day.day}.${day.month}.${day.year}';
}

/// The days the user may pick for "out on"/"back on": every
/// day of the period **plus the day before and the day
/// after** (the flex days -- leave a day early, come back a
/// day late).
List<DateTime> candidateDays(TravelPeriod period) => [
      for (var day = _date(period.start).subtract(const Duration(days: 1));
          !day.isAfter(_date(period.end).add(const Duration(days: 1)));
          day = day.add(const Duration(days: 1)))
        day,
    ];

/// Whether `day` is a flex day (outside the period itself).
bool isFlexDay(TravelPeriod period, DateTime day) =>
    _date(day).isBefore(_date(period.start)) ||
    _date(day).isAfter(_date(period.end));

/// The Friday `day` belongs to: a Monday plans the coming
/// weekend -- on a Monday you plan the weekend ahead -- and
/// a Saturday/Sunday belongs to the Friday that started it.
DateTime fridayOf(DateTime day) {
  final weekday = day.weekday;
  if (weekday == DateTime.monday) {
    return _date(day).add(const Duration(days: 4));
  }
  if (weekday == DateTime.saturday || weekday == DateTime.sunday) {
    return _date(day).add(Duration(days: DateTime.friday - weekday));
  }
  return _date(day).add(Duration(days: DateTime.friday - weekday));
}

/// The first Friday at least `minimumDaysAhead` days after
/// `today`. Too little lead time yields an empty board,
/// which is worse than the following weekend.
DateTime nextFriday(DateTime today, {int minimumDaysAhead = 0}) {
  var ahead = (DateTime.friday - today.weekday) % 7;
  if (ahead == 0) ahead = 7;
  while (ahead < minimumDaysAhead) {
    ahead += 7;
  }
  return _date(today).add(Duration(days: ahead));
}

/// The classic weekend period: the Friday through the
/// Monday ("this weekend" / "next weekend").
TravelPeriod weekendPeriod(DateTime friday) => TravelPeriod(
      friday,
      friday.add(const Duration(days: 3)),
    );

/// The legacy default plan for a Friday-through-Monday
/// period: out Fri from 14:00 or Sat before 12:00, back Sat
/// after 12:00, Sun any time or Mon before 09:00. This is
/// what the presets preselect -- the rules the finder
/// shipped with.
TravelPlan legacyWeekendPlan(DateTime friday, {String label = ''}) {
  final saturday = friday.add(const Duration(days: 1));
  final sunday = friday.add(const Duration(days: 2));
  final monday = friday.add(const Duration(days: 3));
  return TravelPlan(
    label: label,
    outDays: [
      TravelDay(friday, bound: DayBound.after, minutes: 14 * 60),
      TravelDay(saturday, bound: DayBound.before, minutes: 12 * 60),
    ],
    backDays: [
      TravelDay(saturday, bound: DayBound.after, minutes: 12 * 60),
      TravelDay(sunday),
      TravelDay(monday, bound: DayBound.before, minutes: 9 * 60),
    ],
  );
}

/// The custom-period default: the first day out, the last
/// day back, both "any time" -- the user then adds and
/// removes days.
TravelPlan periodPlan(TravelPeriod period) {
  final days = period.days.toList();
  return TravelPlan(
    label: period.describe(),
    outDays: [TravelDay(days.first)],
    backDays: [TravelDay(days.last)],
  );
}

DateTime _date(DateTime day) => DateTime(day.year, day.month, day.day);
