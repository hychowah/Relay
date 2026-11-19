import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_flutter/main.dart';
import 'package:relay_flutter/conversation_view.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/workspace.dart';

void main() {
  test(
    'snapshot activity and progress stay attached to their recorded turn',
    () {
      final snapshot = ConversationSnapshot.fromJson({
        'messages': [
          {'role': 'user', 'text': 'First', 'createdAt': '10:00'},
          {'role': 'user', 'text': 'Second', 'createdAt': '10:02'},
        ],
        'runs': [
          {'id': 'a', 'status': 'completed', 'startedAt': '10:01'},
          {'id': 'b', 'status': 'running', 'startedAt': '10:03'},
        ],
        'tools': [
          {
            'runId': 'b',
            'name': 'app_call',
            'progress': [
              {'message': 'Searching'},
            ],
          },
        ],
        'commands': [
          {
            'id': 'show',
            'deviceId': 'device',
            'tabId': 'window',
            'runId': 'a',
            'kind': 'navigate',
            'status': 'applied',
            'sectionId': 'intro',
          },
        ],
      });
      final turns = responseTurns(snapshot);
      expect(turns.first.commands.single.sectionId, 'intro');
      expect(turns.last.messages.single.text, 'Second');
      expect(turns.last.runs.single.status, 'running');
      expect(turns.last.tools.single.progress!.single['message'], 'Searching');
    },
  );

  testWidgets('new chat, search, Trash and restore use existing records', (
    tester,
  ) async {
    var counter = 1;
    final records = <String, Json>{
      'saved': {
        'id': 'saved',
        'title': 'Saved research',
        'createdAt': '2026-11-18T00:00:00Z',
      },
    };
    final trash = <String>{};
    final saved = <String?>[];
    String? query;
    final w = Workspace(
      api: RelayApi(
        Uri.parse('http://localhost'),
        client: MockClient((request) async {
          final path = request.url.path;
          Object result;
          if (path == '/api/bots') {
            result = [];
          } else if (path == '/api/config') {
            result = {'apps': []};
          } else if (path == '/api/conversations' && request.method == 'POST') {
            final id = 'new-${counter++}';
            result = records[id] = {
              'id': id,
              'title': 'New conversation',
              'reasoningEffort': jsonDecode(request.body)['reasoningEffort'],
            };
          } else if (path.endsWith('/messages')) {
            result = {'id': 'run-1'};
          } else if (path == '/api/conversations') {
            query = request.url.queryParameters['q'];
            result = records.values
                .where(
                  (r) =>
                      !trash.contains(r['id']) &&
                      (r['title'] as String).toLowerCase().contains(
                        (query ?? '').toLowerCase(),
                      ),
                )
                .toList();
          } else if (path == '/api/trash') {
            result = records.values
                .where((r) => trash.contains(r['id']))
                .toList();
          } else {
            final id = request.url.pathSegments[2];
            if (request.method == 'DELETE') {
              trash.add(id);
              result = {'trashed': true};
            } else if (path.endsWith('/restore')) {
              trash.remove(id);
              result = records[id]!;
            } else {
              result = {
                'conversation': records[id],
                'messages': [
                  {'role': 'assistant', 'text': 'Reply for $id'},
                ],
                'runs': [],
                'tools': [],
                'commands': [],
              };
            }
          }
          return http.Response(jsonEncode(result), 200);
        }),
      ),
      deviceId: 'test',
      pages: (_, _) => throw UnimplementedError(),
      saveConversation: (id) async => saved.add(id),
    );
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RelayApp(workspace: w, saveDraft: (_) async {}));
    await w.start();
    await tester.pump();
    await tester.tap(find.byTooltip('Conversation history'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, 'research');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(query, 'research');
    await tester.tap(find.text('Saved research'));
    await tester.pumpAndSettle();
    expect(find.text('Reply for saved'), findsOneWidget);
    expect(saved.last, 'saved');
    await tester.tap(find.byTooltip('Conversation history'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Move conversation to Trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Trash'));
    await tester.pumpAndSettle();
    expect(w.conversationId, isNull);
    expect(saved.last, isNull);
    await tester.tap(find.byTooltip('Show Trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Restore conversation'));
    await tester.pumpAndSettle();
    expect(trash, isEmpty);
    await tester.tap(find.byTooltip('Close history'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New conversation'));
    await tester.pumpAndSettle();
    expect(w.conversationId, isNull);
    expect(records.keys, ['saved'], reason: 'An unsent chat is not saved');
    await w.changeEffort('high');
    expect(records.keys, ['saved']);
    await w.send('Hello');
    await tester.pumpAndSettle();
    expect(w.conversationId, 'new-1');
    expect(records['new-1']!['reasoningEffort'], 'high');
    expect(w.effort, 'high');
    expect(find.text('Reply for new-1'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('late history responses cannot replace a newly selected conversation; missing saved chat recovers', () async {
    final old = Completer<http.Response>();
    final saved = <String?>[];
    final w = Workspace(
      api: RelayApi(
        Uri.parse('http://localhost'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/old')) return old.future;
          if (request.url.path.endsWith('/missing')) {
            return http.Response('{"error":"Conversation not found"}', 404);
          }
          return http.Response(
            jsonEncode({
              'conversation': {'id': 'new'},
              'messages': [],
              'runs': [],
              'tools': [],
              'commands': [],
            }),
            200,
          );
        }),
      ),
      deviceId: 'test',
      pages: (_, _) => throw UnimplementedError(),
      conversationId: 'old',
      saveConversation: (id) async => saved.add(id),
    );
    addTearDown(w.dispose);
    final reading = w.refresh();
    await w.selectConversation('new');
    old.complete(
      http.Response(
        jsonEncode({
          'conversation': {'id': 'old'},
          'messages': [
            {'role': 'assistant', 'text': 'obsolete'},
          ],
          'runs': [],
          'tools': [],
          'commands': [],
        }),
        200,
      ),
    );
    await reading;
    expect(w.messages, isEmpty);
    await w.refresh();
    expect(w.snapshot!.conversation!.id, 'new');
    await w.selectConversation('missing');
    expect(w.conversationId, isNull);
    expect(saved.last, isNull);
    expect(w.error, 'Conversation not found');
  });
}
