import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_flutter/provider_settings.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/workspace.dart';
import 'package:relay_flutter/workspace_dialogs.dart';

void main() {
  testWidgets(
    'provider picker discovers models and saves effort without exposing the saved key',
    (tester) async {
      Json? saved;
      final w = Workspace(
        api: RelayApi(
          Uri.parse('http://localhost'),
          client: MockClient((request) async {
            final path = request.url.path;
            Object data;
            if (path == '/api/settings/provider/models') {
              expect(jsonDecode(request.body), {'mode': 'deepseek'});
              data = {
                'models': [
                  {
                    'id': 'deepseek-flash',
                    'name': 'DeepSeek Flash',
                    'supportsReasoningEffort': true,
                  },
                ],
              };
            } else if (path == '/api/config') {
              data = {
                'apps': [],
                'provider': {'mode': 'deepseek'},
              };
            } else if (path == '/api/bots') {
              data = [];
            } else {
              if (request.method == 'POST') {
                saved = jsonDecode(request.body) as Json;
              }
              data = {
                'mode': 'deepseek',
                'model': 'deepseek-flash',
                'hasKey': true,
                'reasoningEffort': 'low',
              };
            }
            return http.Response(jsonEncode(data), 200);
          }),
        ),
        deviceId: 'test',
        pages: (_, _) => throw UnimplementedError(),
        saveConversation: (_) async {},
      );
      addTearDown(w.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProviderSettings(workspace: w)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('DeepSeek Flash'), findsOneWidget);
      expect(find.text('Replace API key (optional)'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, {
        'mode': 'deepseek',
        'model': 'deepseek-flash',
        'reasoningEffort': 'low',
      });
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('bot editor saves only apps that are still registered', (
    tester,
  ) async {
    Json? saved;
    final w = Workspace(
      api: RelayApi(
        Uri.parse('http://localhost'),
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/api/config') {
            return http.Response(
              jsonEncode({
                'apps': [
                  {'id': 'notes', 'name': 'Notes'},
                ],
                'provider': {},
              }),
              200,
            );
          }
          if (request.method == 'POST') {
            saved = jsonDecode(request.body) as Json;
          }
          return http.Response(path == '/api/bots' ? '[]' : '{}', 200);
        }),
      ),
      deviceId: 'test',
      pages: (_, _) => throw UnimplementedError(),
      saveConversation: (_) async {},
    );
    addTearDown(w.dispose);
    await w.refreshApps();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BotEditor(
            workspace: w,
            bot: {
              'id': 'helper',
              'name': 'Helper',
              'objective': 'Summarize',
              'scope': '',
              'appIds': ['notes', 'removed'],
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Save bot'));
    await tester.pumpAndSettle();
    expect(saved?['appIds'], ['notes']);
  });
  testWidgets('memory editor keeps scope and saves an edited entry', (
    tester,
  ) async {
    Json? saved;
    String? path;
    final api = RelayApi(
      Uri.parse('http://localhost'),
      client: MockClient((request) async {
        path = request.url.path;
        saved = jsonDecode(request.body) as Json;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryEditor(
            api: api,
            botId: 'research',
            entry: {'id': 'm1', 'key': 'Units', 'content': 'Use inches'},
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(EditableText).last, 'Use centimetres');
    await tester.tap(find.text('Save memory'));
    await tester.pumpAndSettle();
    expect(path, '/api/memories/m1');
    expect(saved, {
      'botId': 'research',
      'key': 'Units',
      'content': 'Use centimetres',
    });
  });
}
