import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/web_page.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:uuid/uuid.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native browsing, retained app state and agent presentation', (
    tester,
  ) async {
    final workspace = Workspace(
      api: RelayApi(
        Uri.parse(
          const String.fromEnvironment(
            'RELAY_URL',
            defaultValue: 'http://127.0.0.1:3250',
          ),
        ),
      ),
      deviceId: 'native-check-${const Uuid().v4()}',
      pages: createWebPage,
      saveConversation: (_) async {},
    );
    final connection = BrowserConnection(
      Uri.parse(
        const String.fromEnvironment(
          'BROWSER_URL',
          defaultValue: 'http://127.0.0.1:3251',
        ),
      ),
      workspace.browserSessionId,
      workspace.readBrowser,
      (_) {},
    );
    // SSH-launched tests can be occluded; still render the native test surfaces.
    Future<void> frame() async {
      if (!tester.binding.framesEnabled) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      tester.binding.scheduleWarmUpFrame();
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      RelayApp(
        workspace: workspace,
        saveDraft: (_) async {},
        onClose: connection.close,
      ),
    );
    await workspace.start();
    await connection.connect();
    expect(workspace.error, isNull);

    // Keep pumping real frames while WKWebView loads and its native channel replies.
    Future<T> complete<T>(Future<T> operation) async {
      var finished = false;
      T? result;
      Object? failure;
      operation.then(
        (value) {
          result = value;
          finished = true;
        },
        onError: (Object error) {
          failure = error;
          finished = true;
        },
      );
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (!finished && DateTime.now().isBefore(deadline)) {
        await frame();
      }
      if (failure != null) throw failure!;
      expect(finished, isTrue, reason: 'Native operation timed out');
      return result as T;
    }

    final research = const bool.fromEnvironment('RESEARCH') ||
        !workspace.apps.any((app) => app.id == 'room-layout');
    final targetApp = research ? 'research' : 'room-layout';
    final targetTab = await complete(
      workspace.openApp(
        workspace.apps.firstWhere((app) => app.id == targetApp),
      ),
    );
    debugPrint('Native app ready');
    final targetPage = targetTab.page!;
    final presented = await complete(
      targetPage.present({
        'id': 'native-retention',
        'expectedGeneration': targetPage.context!['generation'],
        'intent': {
          'viewId': research ? '#/hand/products/unitree' : 'room',
          'state': research ? {'language': 'en'} : {'zone': 'work'},
          'targetIds': research
              ? ['model-Dex3-1-dof', 'model-Dex3-1-price']
              : ['desk'],
          'explanation': 'Native bridge check',
        },
      }),
    );
    expect(presented['status'], 'applied');
    debugPrint('Native app presentation passed');
    final browser = await complete(
      workspace.openApp(
        workspace.apps.firstWhere((app) => app.id == 'browser'),
      ),
    );
    await complete(
      workspace.navigate(
        research
            ? 'https://robostore.com/products/unitree-dex3-1-dexterous-hands'
            : 'https://example.com',
      ),
    );
    expect(workspace.error, isNull);
    final page = await complete(browser.page!.browser!.read());
    debugPrint('Browser page read passed');
    expect(
      page['title'],
      research
          ? contains(RegExp('Dex3', caseSensitive: false))
          : contains('Example Domain'),
    );
    const comment = 'This comment belongs to Relay.';
    final result = await complete(
      browser.page!.presentOnCurrentView({
        'id': 'native-browser-comment',
        'intent': {'viewId': 'browser', 'explanation': comment},
      }),
    );
    expect(result['status'], 'applied');
    await frame();
    expect(find.text(comment), findsOneWidget);
    final evidence = await complete(browser.page!.browser!.read());
    expect(evidence['text'], isNot(contains(comment)));
    await tester.tap(find.byTooltip('Dismiss explanation'));
    await frame();
    expect(find.text(comment), findsNothing);
    workspace.select(targetTab);
    await frame();
    expect(identical(targetTab.page, targetPage), isTrue);
    if (research) {
      expect(targetTab.page!.context!['viewId'], '#/hand/products/unitree');
      expect(targetTab.page!.context!['state']['language'], 'en');
    } else {
      expect(targetTab.page!.context!['state']['zone'], 'work');
    }
    workspace.select(browser);
    await frame();

    if (const bool.fromEnvironment('LIVE_AGENT')) {
      await complete(
        workspace.send(
          research
              ? 'Read my current browser page using Browser. Compare its Unitree Dex3-1 '
                    'price and DoF information with the saved evidence in Research Web. '
                    'Keep reseller versus manufacturer and configuration qualifications. '
                    'Open the matching Research company page in English and highlight the '
                    'Dex3-1 price and DoF fields with a short explanation. Use the actual '
                    'app tools and wait for the presentation result. Do not edit research.'
              : 'Use Browser to read my current page, then inspect Room layout. '
                    'Explain briefly whether this page provides furniture guidance. '
                    'Open the Room work zone and highlight the desk with a short explanation. '
                    'Use the actual app tools, and wait for the presentation result.',
        ),
      );
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (workspace.busy && DateTime.now().isBefore(deadline)) {
        await frame();
      }
      expect(workspace.busy, isFalse, reason: 'Agent did not finish');
      expect(workspace.error, isNull);
      expect(workspace.active?.appId, targetApp);
      final commands = workspace.snapshot!.commands;
      expect(
        commands.any(
          (command) =>
              command.appId == targetApp && command.status == 'applied',
        ),
        isTrue,
      );
      final tools = workspace.snapshot!.tools;
      expect(
        tools.any(
          (tool) =>
              tool.name == 'app_call' &&
              (tool.input as Map?)?['appId'] == 'browser' &&
              tool.status == 'completed' &&
              (tool.output as Map?)?['error'] == null,
        ),
        isTrue,
        reason: 'Agent must read the actual browser page',
      );
    }
    debugPrint('Retained tabs passed');
    workspace.closeTab(browser);
    await frame();
    expect(workspace.tabs.contains(browser), isFalse);
    final retainedPage = workspace.active?.page;
    final saved = await workspace.conversations();
    await complete(workspace.newConversation());
    expect(workspace.conversationId, isNull);
    expect(
      (await workspace.conversations()).length,
      saved.length,
      reason: 'An unsent new conversation must not be saved',
    );
    final conversation = await complete(
      workspace.api.createConversation(null, null),
    );
    await complete(workspace.selectConversation(conversation));
    await complete(workspace.trashConversation(conversation));
    expect(workspace.conversationId, isNull);
    expect(
      (await workspace.conversations(trash: true))
          .any((entry) => entry.id == conversation),
      isTrue,
    );
    await complete(workspace.restoreConversation(conversation));
    await complete(workspace.selectConversation(conversation));
    expect(workspace.snapshot!.conversation!.id, conversation);
    expect(identical(workspace.active?.page, retainedPage), isTrue);
    debugPrint('Conversation lifecycle passed');
    if (research) {
      final saved = await complete(
        workspace.openSource({
          'appId': 'research',
          'resourceId': '#/hand/products/unitree',
        }),
      );
      expect(
        saved.error,
        isNull,
        reason: 'Saved Research evidence must open in the native view',
      );
      expect(
        saved.page!.context!['source']['resourceId'],
        '#/hand/products/unitree',
      );
      final focus = await complete(
        saved.page!.present({
          'id': 'saved-focus',
          'kind': 'navigate',
          'source': saved.report!['source'],
          'sectionId': 'model-Dex3-1-price',
          'highlightIds': ['model-Dex3-1-price'],
          'viewState': {'language': 'en'},
        }),
      );
      expect(focus['status'], 'applied');
      debugPrint('Saved source presentation passed');
    }
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
