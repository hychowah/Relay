import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:relay_flutter/conversation_view.dart';
import 'package:relay_flutter/relay_api.dart';
import 'package:relay_flutter/page_surface.dart';
import 'package:relay_flutter/workspace.dart';

import 'workspace_test.dart' show FakePage;

void main() {
  const source = {
    'appId': 'research',
    'resourceId': 'unitree',
    'revision': 'saved',
    'title': 'Unitree',
    'sourceUrl': 'https://research.test/#/hand/products/unitree',
  };
  test('native host encoding preserves nested document routes and bridge parameters', () {
    final url = Uri.parse('http://research.test/_relay/view')
        .replace(
          queryParameters: {
            'resourceId': '#/hand/products/unitree',
            'token': 'native-test',
            'parentOrigin': 'http://relay.test',
          },
        )
        .toString();
    final spec = PageSpec(
      id: 'native-test',
      appId: 'research',
      name: 'Research',
      sessionId: 'session',
      relayOrigin: Uri.parse('http://relay.test'),
      appView: {'url': url, 'origin': 'http://research.test'},
      report: {'source': source},
    );
    final decoded =
        jsonDecode(Uri.decodeComponent(spec.hostUri.fragment)) as Json;
    expect(decoded['url'], url);
    expect(decoded['protocolVersion'], 1);
    expect(
      Uri.parse(decoded['url'] as String).queryParameters['resourceId'],
      '#/hand/products/unitree',
    );
    expect(
      Uri.parse(decoded['url'] as String).queryParameters['token'],
      'native-test',
    );
  });
  test(
    'citations select saved revisions and their applied highlight targets',
    () {
      final sources = responseSources([
        ToolRecord.fromJson({
          'runId': 'run',
          'name': 'app_call',
          'output': {
            'sources': [source, source],
          },
        }),
      ]);
      expect(sources.length, 1);
      expect(citedSource('#/hand/products/unitree', sources), source);
      expect(citedSource('//other.test', sources), isNull);
      final focus = sourceFocus(source, [
        ViewCommand.fromJson({
          'id': 'show',
          'runId': 'run',
          'deviceId': 'device',
          'tabId': 'tab',
          'kind': 'present',
          'status': 'applied',
          'intent': {
            'source': source,
            'targetIds': ['price', 'dof'],
          },
        }),
      ]);
      expect(focus!['highlightIds'], ['price', 'dof']);
      expect(
        sourceFocus(
          {...source, 'revision': 'new'},
          [
            ViewCommand.fromJson({
              'id': 'open',
              'runId': 'run',
              'deviceId': 'device',
              'tabId': 'tab',
              'kind': 'navigate',
              'status': 'applied',
              'source': source,
              'sectionId': 'price',
            }),
          ],
        ),
        isNull,
      );
    },
  );
  test('source reopening requests the exact saved revision and falls back to its report', () async {
    final calls = <Uri>[];
    final w = Workspace(
      api: RelayApi(
        Uri.parse('http://localhost'),
        client: MockClient((request) async {
          calls.add(request.url);
          if (request.url.path.endsWith('/view')) {
            return http.Response('{"error":"View unavailable"}', 503);
          }
          return http.Response(
            jsonEncode({
              'source': source,
              'sections': [
                {'id': 'price', 'title': 'Price', 'text': 'Saved price'},
              ],
            }),
            200,
          );
        }),
      ),
      deviceId: 'test',
      pages: FakePage.new,
      saveConversation: (_) async {},
    );
    addTearDown(w.dispose);
    final tab = await w.openSource(source);
    expect(calls.first.path, '/api/apps/research/report');
    expect(calls.first.queryParameters['revision'], 'saved');
    expect(tab.report!['source'], source);
    expect(tab.error, 'View unavailable');
  });
}
