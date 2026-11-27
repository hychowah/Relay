import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/page_press.dart';

import 'support/fixture.dart';

void main() {
  testWidgets('a press on the page closes the workspace menu', (tester) async {
    final f = Fixture();
    await f.w.start();
    await f.w.openApp(f.w.apps[1]);
    await tester.pumpWidget(
      RelayApp(workspace: f.w, initialDraft: '', saveDraft: (_) async {}),
    );
    await tester.pumpAndSettle();
    final page = find.byKey(ValueKey('page-${f.pages.last.spec.id}'));

    await tester.tap(find.byTooltip('Workspace menu'));
    await tester.pumpAndSettle();
    final item = find.text('App library');
    expect(item, findsOneWidget);

    // A press on the menu itself, drawn over the page, keeps it open.
    pagePressed(tester.getCenter(item));
    await tester.pumpAndSettle();
    expect(item, findsOneWidget);

    pagePressed(tester.getRect(page).bottomLeft + const Offset(20, -20));
    await tester.pumpAndSettle();
    expect(item, findsNothing);
  });
}
