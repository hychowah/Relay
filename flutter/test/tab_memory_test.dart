import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/tab_memory.dart';
import 'package:relay_flutter/tab_preview.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/workspace_tabs.dart';

// A 1-pixel PNG.
final _picture = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _Page extends PageSurface {
  _Page([this.title = 'Page']);
  @override
  final String title;
  int previews = 0;
  @override
  Future<Uint8List?> preview() async {
    previews++;
    return _picture;
  }

  @override
  Widget get widget => const SizedBox();
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

  testWidgets('a VPN tab shows a lock for the globe only where VPN is real', (
    tester,
  ) async {
    final plain = WorkspaceTab(isBrowser: true, name: 'Plain');
    final vpn = WorkspaceTab(isBrowser: true, name: 'Private', vpn: true);
    Future<void> show(bool showVpn) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 48,
            child: WorkspaceTabs(
              tabs: [plain, vpn],
              selected: plain,
              showVpn: showVpn,
              onSelect: (_) {},
              onClose: (_) {},
            ),
          ),
        ),
      ),
    );
    await show(true);
    expect(find.byIcon(Icons.vpn_lock), findsOneWidget);
    expect(find.byIcon(Icons.language), findsOneWidget);
    await show(false);
    expect(find.byIcon(Icons.vpn_lock), findsNothing);
    expect(find.byIcon(Icons.language), findsNWidgets(2));
  });

  testWidgets('a hover card pictures a hidden tab and gives its memory', (
    tester,
  ) async {
    final shown = _Page('Shown'), hidden = _Page('Hidden');
    final tabs = [
      WorkspaceTab(appId: 'browser', isBrowser: true)..page = shown,
      WorkspaceTab(appId: 'browser', isBrowser: true)..page = hidden,
      WorkspaceTab(appId: 'browser', isBrowser: true)
        ..unloaded = (url: 'https://example.com', title: 'Unloaded'),
      WorkspaceTab(appId: 'browser', isBrowser: true)
        ..unloaded = (url: 'https://example.org', title: 'Failed')
        ..error = 'Could not load https://example.org again: offline',
    ];
    final reading = (
      app: 180 << 20,
      pages: {
        shown: (process: 7, bytes: 100 << 20),
        hidden: (process: 8, bytes: 412 << 20),
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 48,
            child: WorkspaceTabs(
              tabs: tabs,
              selected: tabs.first,
              onSelect: (_) {},
              onClose: (_) {},
              hoverCard: (tab, onScreen) => TabPreview(
                tab: tab,
                shown: onScreen,
                read: () async => reading,
              ),
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1, 400));
    addTearDown(mouse.removePointer);
    Future<void> hover(String title) async {
      await mouse.moveTo(const Offset(1, 400));
      await tester.pump(const Duration(seconds: 1));
      await mouse.moveTo(tester.getCenter(find.text(title)));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
    }

    expect(hidden.previews, 0, reason: 'Nothing is captured before a hover.');
    await hover('Hidden');
    expect(hidden.previews, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.text('Memory 412 MB · all pages 512 MB · Relay 180 MB'),
      findsOneWidget,
    );

    await hover('Shown');
    expect(
      imageCache.currentSize + imageCache.liveImageCount,
      0,
      reason: 'A closed card leaves no picture in the image cache.',
    );
    expect(shown.previews, 0, reason: 'A tab on screen needs no picture.');
    expect(
      find.text('Memory 100 MB · all pages 512 MB · Relay 180 MB'),
      findsOneWidget,
    );

    await hover('Unloaded');
    expect(
      find.text('Unloaded to free memory; click to load it again.'),
      findsOneWidget,
    );
    await hover('Failed');
    expect(
      find.text('Could not load https://example.org again: offline'),
      findsOneWidget,
    );
  });
}
