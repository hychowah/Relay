import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/highlight_menu.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/window_capture.dart';

/// A page that shows its menu over itself, as a Browser tab does.
class _Page extends PageSurface {
  _Page(this.menu);
  final HighlightMenu menu;
  @override
  Widget get widget => Stack(
    fit: StackFit.expand,
    children: [
      const ColoredBox(color: Colors.white),
      menu,
    ],
  );
  @override
  String get title => 'Page';
  @override
  String get url => 'https://example.com/';
  @override
  Json? get context => null;
  @override
  Future<void> get ready async {}
  @override
  Future<Json> present(Json command) async => {};
  @override
  void cancel(String commandId) {}
  @override
  void dispose() {}
}

void main() {
  testWidgets('the highlight menu sits by its text, inside the page', (
    tester,
  ) async {
    final chosen = <String>[];
    var removed = 0;
    Future<Rect> show(Rect at, {String? color}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 600,
              height: 400,
              child: PageSlot(
                page: _Page(
                  HighlightMenu(
                    at: at,
                    color: color,
                    onColor: chosen.add,
                    onRemove: color == null ? null : () => removed++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final page = tester.getTopLeft(find.byType(PageSlot));
      final box = find.descendant(
        of: find.byType(HighlightMenu),
        matching: find.byType(Material),
      );
      return tester.getRect(box.first).shift(-page);
    }

    // Above the text, centred on it.
    var menu = await show(const Rect.fromLTRB(200, 200, 300, 220));
    expect(menu.bottom, lessThanOrEqualTo(200));
    expect(menu.center.dx, closeTo(250, 1));
    await tester.tap(find.byTooltip('Highlight in blue'));
    expect(chosen, ['blue']);

    // Below text at the top, and inside the page by its edge.
    menu = await show(const Rect.fromLTRB(0, 0, 20, 16), color: 'green');
    expect(menu.top, greaterThanOrEqualTo(16));
    expect(menu.left, greaterThanOrEqualTo(0));

    // The clicked highlight's colour is marked; Remove asks a second click.
    expect(find.byTooltip('Highlighted in green'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove highlight'));
    await tester.pumpAndSettle();
    expect(removed, 0);
    await tester.tap(find.text('Remove'));
    expect(removed, 1);
  });
}
