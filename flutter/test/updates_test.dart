import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:relay_flutter/app_updates.dart';
import 'package:relay_flutter/relay_api.dart';

void main() {
  test('background download verifies bytes, reuses cache and never installs itself', () async {
    final directory = await Directory.systemTemp.createTemp(
      'relay-update-test',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = utf8.encode('synthetic package');
    var downloads = 0;
    var offline = false;
    final updates = AppUpdates(
      origin: Uri.parse('http://localhost'),
      version: '0.0.2',
      directory: directory,
      client: MockClient((request) async {
        if (offline) throw const SocketException('Connection refused');
        if (request.url.path.endsWith('latest.json')) {
          return http.Response(
            jsonEncode({
              'version': '0.0.3',
              'file': 'Relay-Flutter-0.0.3-macOS-arm64.zip',
              'size': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
            }),
            200,
          );
        }
        downloads++;
        return http.Response.bytes(bytes, 200);
      }),
    );
    addTearDown(updates.dispose);
    await updates.check();
    expect(updates.ready, isTrue);
    expect(updates.progress, 1);
    expect(updates.installing, isFalse);
    await updates.check();
    expect(downloads, 1);
    offline = true;
    await updates.check();
    expect(updates.ready, isTrue);
    expect(await updates.download!.readAsBytes(), bytes);
    offline = false;
    await updates.download!.writeAsString('corrupt');
    await updates.check();
    expect(downloads, 2);
    expect(updates.ready, isTrue);
  });
  test(
    'a file list downloads only changed files and assembles the app',
    () async {
      final root = await Directory.systemTemp.createTemp('relay-files');
      addTearDown(() => root.delete(recursive: true));
      final directory = Directory('${root.path}/updates');
      final running = Directory('${root.path}/Running/Relay Flutter.app');
      await Directory('${running.path}/Contents/Frameworks')
          .create(recursive: true);
      await File('${running.path}/Contents/Frameworks/Engine')
          .writeAsString('engine');
      await File('${running.path}/Contents/Info.plist').writeAsString('old');
      final stored = <String, List<int>>{};
      Json file(String path, String text, {bool exec = false}) {
        final bytes = utf8.encode(text), packed = gzip.encode(bytes);
        final hash = sha256.convert(bytes).toString();
        stored['$hash.gz'] = packed;
        return {
          'path': path,
          'sha256': hash,
          'size': bytes.length,
          'packed': packed.length,
          'exec': exec,
        };
      }

      final listing = utf8.encode(
        jsonEncode([
          file('Contents/Frameworks/Engine', 'engine', exec: true),
          {'path': 'Contents/Frameworks/Current', 'link': 'Engine'},
          file('Contents/Info.plist', 'new'),
          file('Contents/MacOS/Relay Flutter', 'binary', exec: true),
        ]),
      );
      final list = file('list', utf8.decode(listing))..remove('path');
      var version = '0.0.3', corrupt = true;
      final binary = '${sha256.convert(utf8.encode('binary'))}.gz';
      final requests = <String>[];
      final updates = AppUpdates(
        origin: Uri.parse('http://localhost'),
        version: '0.0.2',
        directory: directory,
        bundle: running,
        client: MockClient((request) async {
          final name = request.url.pathSegments.last;
          requests.add(name);
          if (name == 'latest.json') {
            return http.Response(
              jsonEncode({
                'version': version,
                'file': 'Relay-Flutter-$version-macOS-arm64.zip',
                'size': 20000000,
                'sha256': '0' * 64,
                'fileList': list,
              }),
              200,
            );
          }
          if (corrupt && name == binary) {
            return http.Response.bytes(gzip.encode(utf8.encode('bad')), 200);
          }
          return http.Response.bytes(stored[name]!, 200);
        }),
      );
      addTearDown(updates.dispose);

      await updates.check();
      expect(updates.ready, isFalse);
      expect(updates.status, contains('verification failed'));
      // The feed, the list, Info.plist and the binary; the engine is reused.
      expect(requests, hasLength(4));
      corrupt = false;
      requests.clear();
      await updates.check();
      expect(updates.ready, isTrue);
      expect(requests, ['latest.json', binary]);
      await updates.check();
      expect(requests, ['latest.json', binary, 'latest.json']);
      expect(updates.ready, isTrue);

      final app = '${root.path}/Stage/Relay Flutter.app';
      await updates.assemble(app);
      expect(await File('$app/Contents/Info.plist').readAsString(), 'new');
      expect(await Link('$app/Contents/Frameworks/Current').target(), 'Engine');
      expect(
        await File('$app/Contents/Frameworks/Current').readAsString(),
        'engine',
      );
      bool executable(String path) =>
          File('$app/$path').statSync().mode & 0x40 != 0;
      expect(executable('Contents/MacOS/Relay Flutter'), isTrue);
      expect(executable('Contents/Info.plist'), isFalse);

      version = '0.0.2';
      await updates.check();
      expect(await Directory('${directory.path}/files').list().toList(), []);
    },
  );
  test(
    'a started build discards replaced apps, old receipts and old downloads',
    () async {
      final root = await Directory.systemTemp.createTemp('relay-leftovers');
      addTearDown(() => root.delete(recursive: true));
      final directory = await Directory('${root.path}/updates').create();
      final replaced = await Directory(
        '${root.path}/Applications/.relay-flutter-update-abc/Previous.app',
      ).create(recursive: true);
      final unrelated = await Directory(
        '${root.path}/Applications/.other-update-abc',
      ).create();
      for (final name in [
        'launched-0.0.1',
        'launched-0.0.2',
        'Relay-Flutter-0.0.1-macOS-arm64.zip',
        'Relay-Flutter-0.0.2-macOS-arm64.zip.part',
      ]) {
        await File('${directory.path}/$name').writeAsString('old');
      }
      final bytes = utf8.encode('synthetic package');
      final updates = AppUpdates(
        origin: Uri.parse('http://localhost'),
        version: '0.0.2',
        directory: directory,
        client: MockClient(
          (request) async => request.url.path.endsWith('latest.json')
              ? http.Response(
                  jsonEncode({
                    'version': '0.0.3',
                    'file': 'Relay-Flutter-0.0.3-macOS-arm64.zip',
                    'size': bytes.length,
                    'sha256': sha256.convert(bytes).toString(),
                  }),
                  200,
                )
              : http.Response.bytes(bytes, 200),
        ),
      );
      addTearDown(updates.dispose);
      Future<List<String>> names() async => [
        await for (final entry in directory.list()) entry.uri.pathSegments.last,
      ]..sort();

      await updates.discardInstallLeftovers(
        'launched-0.0.2',
        Directory('${root.path}/Applications/Development build.app'),
      );
      expect(await replaced.exists(), isTrue);
      await updates.discardInstallLeftovers(
        'launched-0.0.2',
        Directory('${root.path}/Applications/Relay Flutter.app'),
      );
      expect(await replaced.parent.exists(), isFalse);
      expect(await unrelated.exists(), isTrue);
      await updates.check();
      expect(updates.ready, isTrue);
      expect(await names(), [
        'Relay-Flutter-0.0.3-macOS-arm64.zip',
        'launched-0.0.2',
      ]);
    },
  );
  test(
    'two same-version previews stay selectable and can return to Stable',
    () async {
      final root = await Directory.systemTemp.createTemp('relay-previews');
      addTearDown(() => root.delete(recursive: true));
      final files = <String, List<int>>{};
      Map<String, dynamic> artifact(String? name, String build) {
        final bytes = utf8.encode('fixture $name $build');
        final hash = sha256.convert(bytes).toString();
        final file = name == null
            ? 'Relay-Flutter-0.0.6-macOS-arm64.zip'
            : 'Relay-Flutter-preview-$hash.zip';
        files[file] = bytes;
        return {
          'version': '0.0.6',
          'file': file,
          'size': bytes.length,
          'sha256': hash,
          if (name != null) ...{
            'name': name,
            'commit': 'abcdef0123456789',
            'branch': name,
            'dirty': false,
            'build': build,
          },
        };
      }

      final one = artifact('search', '101'),
          two = artifact('tabs', '102'),
          stable = artifact(null, '6');
      var catalog = [one, two];
      AppUpdates app(String name, String build, {String version = '0.0.6'}) =>
          AppUpdates(
            origin: Uri.parse('http://feed.test'),
            version: version,
            directory: root,
            previewName: name,
            buildNumber: build,
            client: MockClient((req) async {
              final file = req.url.pathSegments.last;
              if (file == 'previews.json') {
                return http.Response(jsonEncode(catalog), 200);
              }
              if (file == 'latest.json') {
                return http.Response(jsonEncode(stable), 200);
              }
              return http.Response.bytes(files[file]!, 200);
            }),
          );
      final current = app('', '6');
      addTearDown(current.dispose);
      await current.loadPreviews();
      final selected = current.previews.first;
      catalog = [artifact('search', '103'), two];
      await current.selectPreview(selected);
      await current.check();
      expect(current.release, one);
      expect(await current.download!.readAsBytes(), files[one['file']]);
      final preview = app('search', '101');
      addTearDown(preview.dispose);
      await preview.check();
      expect(preview.release!['build'], '103');
      await preview.selectPreview(two);
      expect(preview.release, two);
      await preview.selectStable();
      expect(preview.returningToStable, isTrue);
      expect(await preview.download!.readAsBytes(), files[stable['file']]);
      final newerPreview = app('tabs', '102', version: '0.0.7');
      addTearDown(newerPreview.dispose);
      await newerPreview.selectStable();
      expect(newerPreview.ready, isTrue);
      final newerStable = app('', '7', version: '0.0.7');
      addTearDown(newerStable.dispose);
      await newerStable.selectStable();
      expect(newerStable.ready, isFalse);
    },
  );
  testWidgets(
    'Updates shows when the installed app and each test build were built',
    (tester) async {
      String ago(Duration age) =>
          DateTime.now().subtract(age).toUtc().toIso8601String();
      final updates = AppUpdates(
        origin: Uri.parse('http://feed.test'),
        version: '0.0.6',
        directory: Directory.systemTemp,
        previewName: 'tabs',
        buildNumber: '101',
        built: ago(const Duration(hours: 3)),
      );
      addTearDown(updates.dispose);
      Json preview(String name, {String? built}) => {
        'name': name,
        'version': '0.0.6',
        'sha256': 'a' * 64,
        'branch': 'feature/$name',
        'commit': 'abcdef0123456789',
        'built': ?built,
      };
      updates.previews = [
        preview('tabs', built: ago(const Duration(minutes: 24))),
        preview('search'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: UpdateDialog(
            updates: updates,
            busy: () => false,
            install: () async {},
          ),
        ),
      );
      expect(find.textContaining('Built 3 h ago, '), findsOneWidget);
      expect(find.textContaining('Built 24 min ago, '), findsOneWidget);
      // A build published before builds recorded their time lists without one.
      expect(find.text('feature/search · abcdef0'), findsOneWidget);
    },
  );
  test(
    'returning from an offline preview still respects backend restart checks',
    () async {
      http.Response? response;
      final api = RelayApi(
        Uri.parse('http://preview.test'),
        client: MockClient((_) async {
          return response ??
              (throw const SocketException('Connection refused'));
        }),
      );
      addTearDown(api.close);
      Future<void> check(bool allowOffline) => api.checkIdleBeforeRestart(
        'device',
        'window',
        allowOffline: allowOffline,
      );
      await check(true);
      await expectLater(check(false), throwsA(isA<SocketException>()));
      response = http.Response('unavailable', 503);
      await expectLater(check(true), throwsA(isA<RelayApiException>()));
      response = http.Response('{"busy":true}', 200);
      await expectLater(check(true), throwsStateError);
    },
  );
  test(
    'wrong hash and other client packages cannot become installable',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'relay-update-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      var file = 'Relay-Flutter-0.0.3-macOS-arm64.zip';
      final updates = AppUpdates(
        origin: Uri.parse('http://localhost'),
        version: '0.0.2',
        directory: directory,
        client: MockClient(
          (request) async => request.url.path.endsWith('latest.json')
              ? http.Response(
                  jsonEncode({
                    'version': '0.0.3',
                    'file': file,
                    'size': 3,
                    'sha256': '0' * 64,
                  }),
                  200,
                )
              : http.Response('bad', 200),
        ),
      );
      addTearDown(updates.dispose);
      await updates.check();
      expect(updates.ready, isFalse);
      expect(updates.status, contains('verification failed'));
      file = 'Relay-Desktop-0.0.3-macOS-arm64.zip';
      await updates.check();
      expect(updates.ready, isFalse);
      expect(updates.status, contains('incomplete'));
    },
  );
}
