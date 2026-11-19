import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/workspace_style.dart';

void main() {
  testWidgets('deletes only on a second click and cancels elsewhere', (
    tester,
  ) async {
    var deleted = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Text('Elsewhere'),
              ConfirmDeleteButton(
                tooltip: 'Delete item',
                label: 'Delete',
                onConfirmed: () => deleted++,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Delete item'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    expect(deleted, 0);

    await tester.tap(find.text('Elsewhere'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);

    await tester.tap(find.byTooltip('Delete item'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);

    final icon = tester.getCenter(find.byTooltip('Delete item'));
    await tester.tapAt(icon);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(icon);
    await tester.pumpAndSettle();
    expect(deleted, 0, reason: 'A double-click does not delete');
    expect(find.text('Delete'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(find.text('Delete'), findsNothing);
  });
}
