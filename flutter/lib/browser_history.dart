import 'dart:convert';
import 'dart:math' as math;

/// Desktop only. The pages Browser tabs visit, kept on this device for
/// address-bar suggestions. Never sent to the service, the agent or logs.
class BrowserHistory {
  BrowserHistory({this.save, DateTime Function()? now})
    : now = now ?? DateTime.now;

  factory BrowserHistory.decode(
    String? saved, {
    void Function(String)? save,
    DateTime Function()? now,
  }) {
    final history = BrowserHistory(save: save, now: now);
    for (final item in saved == null ? const [] : jsonDecode(saved) as List) {
      final entry = HistoryEntry.fromJson(item as Map<String, dynamic>);
      history._entries[entry.url] = entry;
    }
    history._prune();
    return history;
  }

  static const maxEntries = 1000, shown = 6;
  static const keptFor = Duration(days: 90);

  final void Function(String)? save;
  final DateTime Function() now;
  final _entries = <String, HistoryEntry>{};

  bool get isEmpty => _entries.isEmpty;
  String encode() => jsonEncode([for (final e in _entries.values) e.toJson()]);

  /// Counts a visit to [url]; one entry per page address.
  void visit(String url, [String? title]) {
    final address = historyAddress(url);
    if (address == null) return;
    final known = _entries[address];
    final entry =
        known ?? (_entries[address] = HistoryEntry(address, lastVisit: now()));
    entry
      ..visits += 1
      ..lastVisit = now();
    if (title != null && title.isNotEmpty) entry.title = title;
    if (known == null) _prune();
    _changed();
  }

  /// Updates a page's title once it arrives, without counting a visit.
  void retitle(String url, String title) {
    final entry = _entries[historyAddress(url)];
    if (entry == null || title.isEmpty || entry.title == title) return;
    entry.title = title;
    _changed();
  }

  /// Counts that the user opened [url] from the address bar.
  void typed(String url) {
    final entry = _entries[historyAddress(url)];
    if (entry == null) return;
    entry.typed += 1;
    _changed();
  }

  void clear() {
    _entries.clear();
    _changed();
  }

  /// The pages that best match [text], best first.
  List<HistoryEntry> suggest(String text) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final site = q.replaceFirst(_siteStart, '');
    final wordStart = RegExp(
      '(^|[^\\p{L}\\p{N}])${RegExp.escape(q)}',
      unicode: true,
    );
    double match(HistoryEntry entry) {
      final url = entry.url.toLowerCase(), title = entry.title.toLowerCase();
      if (site.isNotEmpty &&
          url.replaceFirst(_siteStart, '').startsWith(site)) {
        return 20;
      }
      if (wordStart.hasMatch(url) || wordStart.hasMatch(title)) return 4;
      if (url.contains(q) || title.contains(q)) return 1;
      return 0;
    }

    final time = now();
    final scored = [
      for (final entry in _entries.values)
        if (match(entry) case final bonus when bonus > 0)
          (entry: entry, score: bonus * _weight(entry, time)),
    ];
    // A site whose name starts with the text also gets one row for its home
    // page, worth all its pages together, so many single visits to its pages
    // neither crowd out the site nor leave it missing.
    final sites = <String, ({HistoryEntry entry, double score})>{};
    for (final item in scored) {
      final uri = Uri.parse(item.entry.url);
      final name = uri.host.replaceFirst(_siteStart, '');
      if (site.isEmpty || !name.startsWith(site)) continue;
      final home = '${uri.scheme}://${uri.host}/';
      final row = sites[home];
      sites[home] = (
        entry:
            row?.entry ??
            HistoryEntry(
              home,
              title: _entries[home]?.title ?? '',
              lastVisit: item.entry.lastVisit,
            ),
        score: (row?.score ?? 0) + item.score,
      );
    }
    scored
      ..removeWhere((item) => sites.containsKey(item.entry.url))
      ..addAll(sites.values)
      // On a tie the shorter address, a site before its page, comes first.
      ..sort((a, b) {
        final order = b.score.compareTo(a.score);
        if (order != 0) return order;
        final recent = b.entry.lastVisit.compareTo(a.entry.lastVisit);
        return recent != 0
            ? recent
            : a.entry.url.length.compareTo(b.entry.url.length);
      });
    return [for (final item in scored.take(shown)) item.entry];
  }

  static final _siteStart = RegExp(r'^(https?://)?(www\.)?');

  // Typing an address shows more intent than following a link to it.
  static double _weight(HistoryEntry entry, DateTime time) {
    final days = time.difference(entry.lastVisit).inMinutes / (24 * 60);
    final recency = days <= 4
        ? 1.0
        : math.max(.2, math.pow(.2, (days - 4) / 56).toDouble());
    return (entry.visits + 3 * entry.typed) * recency;
  }

  void _prune() {
    final time = now();
    _entries.removeWhere((_, e) => time.difference(e.lastVisit) > keptFor);
    if (_entries.length <= maxEntries) return;
    final ranked = _entries.values.toList()
      ..sort((a, b) {
        final order = _weight(b, time).compareTo(_weight(a, time));
        return order != 0 ? order : b.lastVisit.compareTo(a.lastVisit);
      });
    for (final entry in ranked.skip(maxEntries)) {
      _entries.remove(entry.url);
    }
  }

  void _changed() => save?.call(encode());
}

class HistoryEntry {
  HistoryEntry(
    this.url, {
    this.title = '',
    this.visits = 0,
    this.typed = 0,
    required this.lastVisit,
  });
  HistoryEntry.fromJson(Map<String, dynamic> json)
    : this(
        json['url'] as String,
        title: json['title'] as String,
        visits: json['visits'] as int,
        typed: json['typed'] as int,
        lastVisit: DateTime.fromMillisecondsSinceEpoch(
          json['lastVisit'] as int,
        ),
      );
  final String url;
  String title;
  int visits, typed;
  DateTime lastVisit;
  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'visits': visits,
    'typed': typed,
    'lastVisit': lastVisit.millisecondsSinceEpoch,
  };
}

/// The address history keeps for [url], without its #fragment, or null for
/// pages it skips: anything but an HTTP or HTTPS website.
String? historyAddress(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !['http', 'https'].contains(uri.scheme)) return null;
  if (uri.host.isEmpty) return null;
  return uri.removeFragment().toString();
}
