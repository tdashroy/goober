// Friendly, dependency-free time formatting for ride times.
//
// Goober only ever shows a handful of times — when a scheduled ride is wanted
// for — so a couple of small formatters beat pulling in a localization package.

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// A ride time in the rider's local terms, e.g. "Sat 4 Jul, 6:30 PM". Today's
/// times drop the date ("6:30 PM") — for a beach-trip ride, "today" is the
/// common case and the date is just noise.
String formatRideTime(DateTime time, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final clock = formatClockTime(time);
  if (_isSameDay(time, today)) return clock;
  return '${_weekdays[time.weekday - 1]} ${time.day} '
      '${_months[time.month - 1]}, $clock';
}

/// A ride's day in the rider's local terms: "Today", "Tomorrow", or a date
/// ("Sat 4 Jul"). The near days are named because that's what the rides are —
/// naming them beats making someone read a date to learn it's this afternoon.
String formatRideDay(DateTime day, {DateTime? now}) {
  final today = now ?? DateTime.now();
  // Compared calendar day by calendar day: subtracting the instants would call
  // the day after a clocks-change 23 hours, and so not tomorrow.
  if (_isSameDay(day, today)) return 'Today';
  if (_isSameDay(day, DateTime(today.year, today.month, today.day + 1))) {
    return 'Tomorrow';
  }
  return '${_weekdays[day.weekday - 1]} ${day.day} ${_months[day.month - 1]}';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// The clock part alone, e.g. "6:30 PM".
String formatClockTime(DateTime time) {
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final meridiem = time.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $meridiem';
}
