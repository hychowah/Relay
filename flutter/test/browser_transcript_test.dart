import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/browser_transcript.dart';

void main() {
  test('caption lines become timed paragraphs read in byte-bounded pages', () {
    final transcript = transcriptFromSegments({
      'url': 'https://www.youtube.com/watch?v=video',
      'title': 'Talk',
      'language': 'English',
      'segments': [
        for (var i = 0; i < 2000; i++)
          {
            'time': '${i ~/ 60}:${(i % 60).toString().padLeft(2, '0')}',
            'text': 'Line $i says something\nworth 一 hearing.',
          },
        {'time': '33:20', 'text': '  '},
      ],
    });
    final text = transcript['text'] as String;
    final paragraphs = text.split('\n');
    expect(paragraphs.first, startsWith('[0:00] Line 0 says something worth'));
    expect(
      paragraphs.every((p) => RegExp(r'^\[\d+:\d\d\] ').hasMatch(p)),
      isTrue,
    );
    expect(paragraphs.length, lessThan(2000 ~/ 10));

    final pages = <Map<String, dynamic>>[];
    for (
      int? offset = 0;
      offset != null;
      offset = pages.last['nextOffset'] as int?
    ) {
      pages.add(transcriptPage(transcript, offset));
    }
    expect(pages.length, greaterThan(1));
    expect(pages.map((page) => page['text']).join(), text);
    for (final page in pages) {
      expect(
        utf8.encode(page['text'] as String).length,
        lessThanOrEqualTo(transcriptPageBytes),
      );
      expect(page['title'], 'Talk');
      expect(page['totalLength'], text.length);
    }
    expect(() => transcriptPage(transcript, text.length), throwsRangeError);
  });
}
