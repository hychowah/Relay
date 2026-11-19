import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/browser_history.dart';

void main() {
  late DateTime time;
  late BrowserHistory history;
  setUp(() {
    time = DateTime(2026, 11, 19, 12);
    history = BrowserHistory(now: () => time);
  });

  /// Visits [url] [visits] times, [daysAgo] days ago, typing it [typed] times.
  void visit(
    String url, {
    int visits = 1,
    int typed = 0,
    int daysAgo = 0,
    String? title,
  }) {
    final today = time;
    time = today.subtract(Duration(days: daysAgo));
    for (var i = 0; i < visits; i++) {
      history.visit(url, title);
    }
    for (var i = 0; i < typed; i++) {
      history.typed(url);
    }
    time = today;
  }

  List<String> suggested(String text) => [
    for (final entry in history.suggest(text)) entry.url,
  ];

  test('keeps one entry per page address and only web pages', () {
    visit('https://example.com/a#intro', title: 'Example A');
    visit('https://example.com/a#details');
    visit('about:blank');
    visit('file:///Users/me/notes.html');
    history.retitle('https://example.com/a#later', 'Example A, renamed');

    final [entry] = history.suggest('example.com/a');
    expect(entry.url, 'https://example.com/a');
    expect(entry.visits, 2);
    expect(entry.title, 'Example A, renamed');
    expect(suggested('notes'), isEmpty);
  });

  test('ranks often, typed and recent pages first', () {
    visit('https://example.com/rare');
    visit('https://example.com/often', visits: 5);
    expect(suggested('example.com/'), [
      'https://example.com/often',
      'https://example.com/rare',
    ]);

    // One typed visit outweighs three clicked ones.
    visit('https://typed.test/', typed: 1);
    visit('https://clicked.test/', visits: 3);
    expect(suggested('test'), ['https://typed.test/', 'https://clicked.test/']);

    // Visits from two months ago count for less than this week's.
    visit('https://old.test/news', visits: 5, daysAgo: 60);
    visit('https://new.test/news', visits: 2, daysAgo: 1);
    expect(suggested('news'), [
      'https://new.test/news',
      'https://old.test/news',
    ]);
  });

  test('prefers the start of a site, then of a word, then any match', () {
    visit('https://www.github.com/');
    visit('https://blog.example/git-tips', visits: 4);
    visit('https://digital.example/', visits: 10);
    visit('https://unrelated.example/', visits: 50);
    expect(suggested('git'), [
      'https://www.github.com/',
      'https://blog.example/git-tips',
      'https://digital.example/',
    ]);
    expect(suggested('https://www.GitHub'), ['https://www.github.com/']);
    expect(suggested('   '), isEmpty);
  });

  test('one row for a site gathers its pages', () {
    for (var i = 0; i < 10; i++) {
      visit('https://www.youtube.com/watch?v=$i', title: 'Video $i');
    }
    visit('https://youtube-fan.example/', visits: 20, daysAgo: 30);
    final [first, ...rest] = history.suggest('you');
    expect(first.url, 'https://www.youtube.com/');
    expect(rest, hasLength(5));

    visit('https://www.youtube.com/', title: 'YouTube');
    expect(history.suggest('you').first.title, 'YouTube');
    expect(
      suggested('you').where((url) => url == 'https://www.youtube.com/'),
      hasLength(1),
    );
  });

  test('shows the best six', () {
    for (var i = 1; i <= 8; i++) {
      visit('https://site$i.example/', visits: i);
    }
    expect(suggested('site'), [
      for (var i = 8; i >= 3; i--) 'https://site$i.example/',
    ]);
  });

  test('forgets pages after 90 days and keeps the best 1000', () {
    visit('https://stale.example/', visits: 20, daysAgo: 91);
    visit('https://kept.example/', daysAgo: 89);
    history = BrowserHistory.decode(history.encode(), now: () => time);
    expect(suggested('example'), ['https://kept.example/']);

    for (var i = 0; i < 1000; i++) {
      visit('https://page$i.example/', visits: 2);
    }
    expect(jsonDecode(history.encode()), hasLength(1000));
    expect(suggested('kept'), isEmpty, reason: 'the weakest page goes');
    expect(suggested('page999'), ['https://page999.example/']);
  });

  test('clear forgets every page and saves that', () {
    var saved = '';
    history = BrowserHistory(now: () => time, save: (data) => saved = data);
    visit('https://example.com/');
    expect(BrowserHistory.decode(saved).isEmpty, isFalse);

    history.clear();
    expect(history.isEmpty, isTrue);
    expect(suggested('example'), isEmpty);
    expect(BrowserHistory.decode(saved).isEmpty, isTrue);
  });
}
