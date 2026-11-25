import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';

import 'support/fake_page.dart';
import 'support/fixture.dart';

void main() {
  testWidgets('a Browser tab highlights selected text, and zooms a PDF', (
    tester,
  ) async {
    final f = Fixture();
    await f.w.start();
    final pdf = (await f.w.openApp(f.w.apps[0])).page! as FakePage;
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: f.w, saveDraft: (_) async {}));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Zoom in'), findsNothing);
    // With nothing selected there is nothing to highlight.
    IconButton highlight() =>
        tester.widget(find.widgetWithIcon(IconButton, Icons.border_color));
    pdf.selection = '';
    pdf.changed(false);
    await tester.pumpAndSettle();
    expect(highlight().onPressed, isNull);

    pdf.pdf = true;
    pdf.changed(false);
    await tester.pumpAndSettle();
    for (final button in ['Zoom out', 'Zoom in', 'Fit to width']) {
      await tester.tap(find.byTooltip(button));
    }
    expect(pdf.actions, ['zoomOut', 'zoomIn', 'zoomFit']);
    expect(highlight().onPressed, isNull);

    pdf.selection = 'selected passage';
    pdf.changed(true);
    await tester.pumpAndSettle();
    highlight().onPressed!();
    expect(pdf.actions.last, 'highlight');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'address bar asks the server for visited pages as the user types',
    (tester) async {
      final f = Fixture()
        ..historyPages = [
          {'url': 'https://example.com/', 'title': ''},
          {'url': 'https://example.com/desk', 'title': 'Desk'},
          {'url': 'https://news.example/', 'title': 'News'},
        ];
      await f.w.start();
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.single;
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}, browserHistory: true),
      );
      await tester.pumpAndSettle();
      final address = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Search or enter a web address',
      );
      // Entered at once over the whole address, as a paste after a focusing
      // click, so nothing fills in.
      Future<void> type(String text) async {
        final controller = tester.widget<TextField>(address).controller!;
        controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: controller.text.length,
        );
        await tester.enterText(address, text);
        await tester.pumpAndSettle();
      }

      Future<void> submit() async {
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }

      // The address the app wrote asks for nothing, even with the field focused.
      await tester.tap(address);
      await tester.pumpAndSettle();
      expect(f.history, isEmpty);
      expect(find.text('Desk'), findsNothing);

      // Browsing history stays out of bug recordings.
      f.w.recorder.start();
      await type('exa');
      expect(f.history, ['suggest exa']);
      expect(find.text('Desk'), findsOneWidget);
      expect(find.text('News'), findsOneWidget);
      await submit();
      expect(page.navigated, ['exa'], reason: 'nothing was highlighted');
      expect(find.text('Desk'), findsNothing);
      expect(
        f.history.last,
        'POST /api/browser-history/typed {"url":"https://example.com/desk"}',
      );

      await type('exa');
      // Below the example.com site row and its desk page.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await submit();
      expect(page.navigated.last, 'https://news.example/');

      // Typing again returns the highlight to the typed text.
      await type('exa');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await type('exam');
      await submit();
      expect(page.navigated.last, 'exam');

      // A slow answer for older text never replaces the newer one, and Enter
      // opens the text in the field while the earlier list is still shown.
      f.holdHistory['e'] = Completer();
      await type('e');
      await type('ne');
      expect(find.text('News'), findsOneWidget);
      f.holdHistory['e']!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Desk'), findsNothing);
      f.holdHistory['new'] = Completer();
      await type('new');
      await submit();
      expect(page.navigated.last, 'new');
      f.holdHistory['new']!.complete();
      await tester.pumpAndSettle();
      expect(find.text('News'), findsNothing);
      expect(tester.widget<TextField>(address).controller!.text, 'new');

      await type('news');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('News'), findsNothing);
      await submit();
      expect(page.navigated.last, 'news');

      await type('ne');
      await tester.tap(find.text('News'));
      await tester.pumpAndSettle();
      expect(page.navigated.last, 'https://news.example/');

      // A new page address replaces typed text without opening suggestions.
      await type('ne');
      expect(find.text('News'), findsOneWidget);
      final asked = f.history.length;
      page.url = 'https://example.com/';
      f.w.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(address).controller!.text, page.url);
      expect(find.text('Desk'), findsNothing);
      expect(find.text('News'), findsNothing);
      expect(f.history, hasLength(asked));

      // An older backend without history shows no suggestions.
      f.historyPages = null;
      await type('desk');
      expect(find.text('Desk'), findsNothing);

      expect(
        f.w.recorder.events.where((e) => '${e['path']}'.contains('history')),
        isEmpty,
      );
      f.w.recorder.stop();
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('inline completion continues the typed text with the best address', () {
    expect(inlineCompletion('you', 'https://www.youtube.com/'), 'youtube.com');
    expect(inlineCompletion('YOU', 'https://www.youtube.com/'), 'YOUtube.com');
    expect(
      inlineCompletion('www.you', 'https://youtube.com/'),
      'www.youtube.com',
    );
    expect(
      inlineCompletion('HTTPS://you', 'http://www.YouTube.com/watch?v=1'),
      'HTTPS://youTube.com/watch?v=1',
    );
    expect(inlineCompletion('ex', 'https://example.com/a/'), 'example.com/a/');
    expect(inlineCompletion('tube', 'https://youtube.com/'), isNull);
    expect(inlineCompletion('youtube.com', 'https://youtube.com/'), isNull);
    expect(inlineCompletion('www.', 'https://www.youtube.com/'), isNull);
  });

  testWidgets(
    'address bar selects all on a focusing click and fills in the best page',
    (tester) async {
      final f = Fixture()
        ..historyPages = [
          {'url': 'http://www.example.com/', 'title': ''},
          {'url': 'https://example.com/desk', 'title': 'Desk'},
        ];
      await f.w.start();
      await f.w.openApp(f.w.apps[0]);
      final page = f.pages.single;
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RelayApp(workspace: f.w, saveDraft: (_) async {}, browserHistory: true),
      );
      await tester.pumpAndSettle();
      final address = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == 'Search or enter a web address',
      );
      final field = tester.widget<TextField>(address).controller!;
      TextEditingValue shown(String text, [int? typed]) => TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: typed ?? text.length,
          extentOffset: text.length,
        ),
      );
      Future<void> edit(TextEditingValue value) async {
        tester.testTextInput.updateEditingValue(value);
        await tester.pumpAndSettle();
      }

      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      // The click that focuses the bar selects the address; the next one
      // places the caret.
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(field.selection, TextSelection(baseOffset: 0, extentOffset: 24));
      await tester.pump(kDoubleTapTimeout);
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(field.selection.isCollapsed, isTrue);

      // A paste fills nothing in; the next typed character fills in the best
      // page after the typed text, asking for nothing more.
      await edit(shown(''));
      await edit(shown('exa'));
      expect(field.value, shown('exa'));
      expect(find.text('Desk'), findsOneWidget);
      await edit(shown('exam'));
      expect(field.value, shown('example.com', 4));
      expect(f.history, ['suggest exa', 'suggest exam']);
      // Typing what is filled in next keeps the fill-in at once.
      await edit(shown('examp'));
      expect(field.value, shown('example.com', 5));
      expect(f.history, ['suggest exa', 'suggest exam', 'suggest examp']);
      // Deleting removes the fill-in and fills nothing in again.
      await key(LogicalKeyboardKey.backspace);
      expect(field.value, shown('examp'));
      await key(LogicalKeyboardKey.backspace);
      expect(field.value, shown('exam'));
      await edit(shown('examp'));
      expect(field.value, shown('example.com', 5));
      // Esc removes the fill-in and closes the list.
      await key(LogicalKeyboardKey.escape);
      expect(field.value, shown('examp'));
      expect(find.text('Desk'), findsNothing);

      // Enter and Go open the filled-in page's own URL, not the shown text,
      // also once the caret has accepted the fill-in.
      field.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await edit(shown('e'));
      expect(field.value, shown('example.com', 1));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated, ['http://www.example.com/']);
      expect(
        f.history.last,
        'POST /api/browser-history/typed {"url":"https://example.com/desk"}',
      );
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('e'));
      expect(field.value, shown('example.com', 1));
      await key(LogicalKeyboardKey.arrowRight);
      expect(field.value, shown('example.com'));
      await tester.tap(find.byTooltip('Go'));
      await tester.pumpAndSettle();
      expect(page.navigated, List.filled(2, 'http://www.example.com/'));
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('e'));
      await key(LogicalKeyboardKey.arrowRight);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated, List.filled(3, 'http://www.example.com/'));
      // With nothing filled in, as after a paste, Enter opens the text as is.
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('exa'));
      expect(field.value, shown('exa'));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated.last, 'exa');
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await edit(shown('desk'));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(page.navigated.last, 'desk');

      // An answer fills nothing in once the text or caret has moved on.
      await tester.tap(address, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      f.holdHistory['e'] = Completer();
      f.holdHistory['ex'] = Completer();
      await edit(shown('e'));
      await edit(shown('ex'));
      await edit(shown('ex?'));
      f.holdHistory['e']!.complete();
      f.holdHistory['ex']!.complete();
      await tester.pumpAndSettle();
      expect(field.value, shown('ex?'));
      f.holdHistory['exa'] = Completer();
      await edit(shown('exa'));
      await key(LogicalKeyboardKey.arrowLeft);
      f.holdHistory['exa']!.complete();
      await tester.pumpAndSettle();
      expect(field.text, 'exa');
      expect(field.selection, const TextSelection.collapsed(offset: 2));

      // Nothing fills in while an input method is composing.
      await edit(shown(''));
      const composing = TextEditingValue(
        text: 'exa',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      await edit(composing);
      expect(field.value, composing);
      await edit(shown('exa'));
      expect(field.value, shown('example.com', 3));
      await tester.pumpWidget(const SizedBox());
    },
    // A click on macOS places the caret as the mouse goes down.
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
