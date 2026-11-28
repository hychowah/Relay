import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/browser_downloads.dart';

void main() {
  late Directory folder;
  late GlobalKey<ScaffoldMessengerState> messenger;
  late BrowserDownloads downloads;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('relay-downloads-');
    messenger = GlobalKey<ScaffoldMessengerState>();
    downloads = BrowserDownloads(messenger, folder: () async => folder);
  });
  tearDown(() => folder.deleteSync(recursive: true));

  Future<void> showApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(scaffoldMessengerKey: messenger, home: const Scaffold()),
  );

  String name(String? path) => path!.split(Platform.pathSeparator).last;

  testWidgets('a download gets a name no file or running download has', (
    tester,
  ) async {
    await showApp(tester);
    File('${folder.path}/report.pdf').writeAsStringSync('old');
    final first = await downloads.start('blob:https://a.test/1', 'report.pdf');
    final second = await downloads.start('blob:https://a.test/2', 'report.pdf');
    expect([name(first), name(second)], ['report (1).pdf', 'report (2).pdf']);
    expect(first, startsWith(folder.path));
    expect(
      name(await downloads.start('data:text/plain,x', 'README')),
      'README',
    );
    expect(
      name(await downloads.start('data:text/plain,x', 'README')),
      'README (1)',
    );
    expect(name(await downloads.start('data:text/plain,x', '.env')), '.env');
    expect(
      name(await downloads.start('data:text/plain,x', '.env')),
      '.env (1)',
    );
  });

  testWidgets('a site cannot name a folder or a forbidden character', (
    tester,
  ) async {
    await showApp(tester);
    expect(
      name(await downloads.start('blob:x', '../../etc/pass:wd')),
      'pass_wd',
    );
    expect(name(await downloads.start('blob:x', r'C:\a\..')), 'download');
  });

  testWidgets('the notice follows the download to its end', (tester) async {
    await showApp(tester);
    final path = await downloads.start('blob:x', 'notes.txt');
    await tester.pump();
    expect(find.text('Downloading notes.txt…'), findsOneWidget);

    downloads.ended(path!, saved: true);
    await tester.pumpAndSettle();
    expect(find.text('Saved notes.txt'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Show'), findsOneWidget);

    final failed = await downloads.start('blob:x', 'notes.txt');
    expect(name(failed), 'notes.txt', reason: 'the ended download let go');
    downloads.ended(failed!, saved: false);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't download notes.txt"), findsOneWidget);
  });

  testWidgets('a private address saves nothing', (tester) async {
    await showApp(tester);
    final path = await tester.runAsync(
      () => downloads.start('http://127.0.0.1/a.txt', 'a.txt'),
    );
    expect(path, isNull);
    await tester.pumpAndSettle();
    expect(find.text("Couldn't download a.txt"), findsOneWidget);
  });
}
