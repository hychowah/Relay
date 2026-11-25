
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_flutter/main.dart';

import 'support/fixture.dart';

void main() {
  testWidgets(
    'chat can reverse mid-slide and reduced motion closes immediately',
    (tester) async {
      final f = Fixture();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dispatcher = tester.binding.platformDispatcher;
      addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(
        RelayApp(
          workspace: f.w,
          initialDraft: 'Keep this draft',
          saveDraft: (_) async {},
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byTooltip('Toggle chat');
      final panel = find.byKey(const ValueKey('conversation-panel'));
      final docked = tester.getTopLeft(panel).dx;
      await tester.tap(toggle);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.getTopLeft(panel).dx, inExclusiveRange(docked, 1200));
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(panel).dx, docked);
      expect(find.text('Keep this draft'), findsOneWidget);

      dispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      await tester.tap(toggle);
      await tester.pump();
      expect(panel, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('chat reopens closed when it was left closed', (tester) async {
    final f = Fixture();
    final saved = <bool>[];
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RelayApp(
        workspace: f.w,
        initialChatOpen: false,
        saveChatOpen: (open) async => saved.add(open),
        saveDraft: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('conversation-panel'));
    expect(panel, findsNothing);
    await tester.tap(find.byTooltip('Toggle chat'));
    await tester.pumpAndSettle();
    expect(panel, findsOneWidget);
    expect(saved, [true]);
    await tester.pumpWidget(const SizedBox());
  });
}
