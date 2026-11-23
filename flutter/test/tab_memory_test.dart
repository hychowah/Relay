import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/tab_memory.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/workspace_tabs.dart';

class _Page extends PageSurface {
  @override
  Widget get widget => const SizedBox();
  @override
  String get title => 'Page';
  @override
  String get url => 'about:blank';
  @override
  Json? get context => null;
  @override
  Future<void> get ready => Future.value();
  @override
  Future<Json> present(Json command) async => {};
  @override
  void cancel(String commandId) {}
  @override
  void dispose() {}
}

void main() {
  testWidgets('tab memory reads only while on and redraws on a new figure', (
    tester,
  ) async {
    final pages = [_Page(), _Page()];
    final tabs = [
      for (final (i, page) in pages.indexed)
        WorkspaceTab(appId: 'browser', name: 'Tab $i', isBrowser: true)
          ..page = page,
    ];
    var reads = 0, first = 412 << 20;
    final memory = TabMemory((_) async {
      reads++;
      return (
        app: 180 << 20,
        pages: {
          pages[0]: (process: 7, bytes: first),
          pages[1]: (process: 8, bytes: 1536 << 20),
        },
      );
    }, () => pages);
    addTearDown(memory.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 48,
            child: ValueListenableBuilder(
              valueListenable: memory,
              builder: (_, reading, _) => WorkspaceTabs(
                tabs: tabs,
                selected: tabs.first,
                onSelect: (_) {},
                onClose: (_) {},
                memory: reading,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(reads, 0);

    memory.show(true);
    await tester.pump();
    await tester.pump();
    expect(reads, 1);
    expect(find.text('412 MB'), findsOneWidget);
    expect(find.text('1.5 GB'), findsOneWidget);

    var heard = 0;
    memory.addListener(() => heard++);
    await tester.pump(const Duration(seconds: 2));
    expect((reads, heard), (2, 0));

    first = 500 << 20;
    await tester.pump(const Duration(seconds: 2));
    expect((reads, heard), (3, 1));
    expect(find.text('500 MB'), findsOneWidget);

    memory.show(false);
    await tester.pump(const Duration(seconds: 6));
    expect(reads, 3);
    expect(find.textContaining(' MB'), findsNothing);
  });
}
