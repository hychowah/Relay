import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'relay_api.dart';

class AppUpdates extends ChangeNotifier {
  AppUpdates({
    required Uri origin,
    required this.version,
    required this.directory,
    this.previewName = '',
    this.buildNumber = '',
    http.Client? client,
  }) : api = RelayApi(origin, client: client);
  final RelayApi api;
  Uri get origin => api.origin;
  final String version, previewName, buildNumber;
  List<Json> previews = [];
  String? catalogError;
  bool _pinned = false;
  bool get returningToStable =>
      previewName.isNotEmpty && release != null && release!['name'] == null;
  String get installedLabel => previewName.isEmpty
      ? 'Stable $version'
      : '$previewName · $version (build $buildNumber)';
  static String label(Json data) => data['name'] == null
      ? 'Stable ${data['version']}'
      : "${data['name']} · ${data['version']} · ${(data['sha256'] as String).substring(0, 8)}";
  final Directory directory;
  Timer? timer;
  Json? release;
  File? archive;
  String status = 'No update checked yet';
  double? progress;
  bool working = false, installing = false, closed = false;
  bool get ready => archive != null;
  void changed() {
    if (!closed) notifyListeners();
  }

  static Future<AppUpdates?> create(Uri origin) async {
    if (!Platform.isMacOS) return null;
    final info = await PackageInfo.fromPlatform();
    final support = await getApplicationSupportDirectory();
    final updates = AppUpdates(
      origin: origin,
      version: info.version,
      buildNumber: info.buildNumber,
      previewName: const String.fromEnvironment('RELAY_PREVIEW'),
      directory: Directory('${support.path}/updates'),
    );
    await updates.directory.create(recursive: true);
    final identity = updates.previewName.isEmpty
        ? info.version
        : '${info.version}-${info.buildNumber}';
    final receipt = 'launched-$identity';
    await File('${updates.directory.path}/$receipt').writeAsString('ready');
    await updates.discardInstallLeftovers(
      receipt,
      File(Platform.resolvedExecutable).parent.parent.parent,
    );
    updates.timer = Timer.periodic(
      const Duration(hours: 1),
      (_) => updates.check(),
    );
    unawaited(updates.check());
    return updates;
  }

  /// Once this build has started, the apps that earlier installs replaced and
  /// other builds' launch receipts have no further use. The helper script only
  /// needs the replaced app until the new one starts; every published Stable
  /// package stays in the served release directory for recovery.
  Future<void> discardInstallLeftovers(String receipt, Directory bundle) async {
    try {
      await for (final entry in directory.list()) {
        final name = entry.path.split('/').last;
        if (name.startsWith('launched-') && name != receipt) {
          await entry.delete();
        }
      }
      if (!bundle.path.endsWith('/Relay Flutter.app')) return;
      await for (final entry in bundle.parent.list()) {
        final name = entry.path.split('/').last;
        if (entry is Directory && name.startsWith('.relay-flutter-update-')) {
          await entry.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Leftovers that cannot be removed must not stop the app from starting.
    }
  }

  // Only a download that is ready to install is worth its disk space.
  Future<void> _discardDownloads({File? except}) async {
    try {
      await for (final entry in directory.list()) {
        if (entry is File &&
            entry.path != except?.path &&
            (entry.path.endsWith('.zip') || entry.path.endsWith('.part'))) {
          await entry.delete();
        }
      }
    } on FileSystemException {
      // A stale download that cannot be removed does not affect updating.
    }
  }

  Future<dynamic> _manifest(String path) async {
    final response = await api.updateFeed(path);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StateError('Could not reach the update feed.');
    }
    return jsonDecode(response.body);
  }

  static Json _release(dynamic raw, {required bool preview}) {
    if (raw is! Json) throw StateError('The published update is incomplete.');
    final version = raw['version'], hash = raw['sha256'];
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        raw['size'] is! int ||
        (raw['size'] as int) <= 0 ||
        raw['file'] !=
            (preview
                ? 'Relay-Flutter-preview-$hash.zip'
                : 'Relay-Flutter-$version-macOS-arm64.zip') ||
        (preview
            ? raw['name'] is! String ||
                  raw['build'] is! String ||
                  raw['commit'] is! String ||
                  (raw['commit'] as String).length < 7
            : raw['name'] != null)) {
      throw StateError('The published update is incomplete.');
    }
    return raw;
  }

  Future<void> loadPreviews() async {
    try {
      final entries = await _manifest('previews.json') as List? ?? [];
      previews = entries.map((item) => _release(item, preview: true)).toList();
      catalogError = null;
    } catch (e) {
      catalogError = 'Test build list unavailable. Check the update feed.';
    }
    changed();
  }

  Future<void> check() => _prepare();
  Future<void> selectStable() => _prepare(explicit: true);
  Future<void> selectPreview(Json choice) =>
      _prepare(choice: choice, explicit: true);

  Future<void> _prepare({Json? choice, bool explicit = false}) async {
    if (working || installing || closed) return;
    if (!explicit && _pinned) return;
    working = true;
    _pinned = false;
    if (explicit) {
      archive = null;
      release = null;
    }
    status = 'Checking for updates…';
    progress = null;
    changed();
    try {
      final followPreview = !explicit && previewName.isNotEmpty;
      if (followPreview) {
        await loadPreviews();
        if (catalogError != null) throw StateError(catalogError!);
        choice = previews
            .where((item) => item['name'] == previewName)
            .firstOrNull;
      }
      final raw =
          choice ?? (followPreview ? null : await _manifest('latest.json'));
      final data = raw == null ? null : _release(raw, preview: choice != null);
      archive = null;
      release = null;
      if (data == null) {
        status = followPreview
            ? 'This test build is no longer listed. Stable is available in Updates.'
            : 'No Stable release has been published.';
        return;
      }
      final next = data['version'] as String;
      final a = next.split('.').map(int.parse).toList(),
          b = version.split('.').map(int.parse).toList();
      final difference =
          List.generate(
            3,
            (i) => a[i] - b[i],
          ).where((d) => d != 0).firstOrNull ??
          0;
      final current = choice == null
          ? previewName.isEmpty && difference <= 0
          : previewName == choice['name'] && buildNumber == choice['build'];
      if (current) {
        status = 'You have the latest published version';
        await _discardDownloads();
        return;
      }
      release = data;
      final destination = File('${directory.path}/${data['file']}');
      await directory.create(recursive: true);
      if (!await verified(destination, data)) {
        status = 'Downloading ${label(data)}…';
        progress = 0;
        changed();
        final partial = File('${destination.path}.part');
        final download = await api.updateArchive(data['file'] as String);
        if (download.statusCode != 200) {
          throw StateError('The update could not be downloaded.');
        }
        final sink = partial.openWrite();
        var bytes = 0;
        try {
          await for (final chunk in download.stream.timeout(
            const Duration(seconds: 30),
          )) {
            bytes += chunk.length;
            if (bytes > (data['size'] as int)) {
              throw StateError('Unexpected update size.');
            }
            sink.add(chunk);
            progress = bytes / (data['size'] as int);
            changed();
          }
          await sink.flush();
          await sink.close();
          if (!await verified(partial, data)) {
            throw StateError(
              'Update verification failed. The installed app has not changed.',
            );
          }
          await partial.rename(destination.path);
        } catch (_) {
          await sink.close();
          if (await partial.exists()) await partial.delete();
          rethrow;
        }
      }
      archive = destination;
      await _discardDownloads(except: destination);
      _pinned = explicit;
      status = '${label(data)} is ready to install';
      progress = 1;
    } catch (e) {
      status = ready
          ? 'Could not refresh the feed. ${label(release!)} is still ready to install.'
          : e.toString();
      if (ready) progress = 1;
    } finally {
      working = false;
      changed();
    }
  }

  Future<bool> verified(File file, Json data) async =>
      await file.exists() &&
      await file.length() == data['size'] &&
      (await sha256.bind(file.openRead()).first).toString() == data['sha256'];

  Future<void> install(Future<void> Function() preserveDraft) async {
    if (!ready || working || installing) return;
    installing = true;
    status = 'Preparing update…';
    changed();
    try {
      if (!await verified(archive!, release!)) {
        throw StateError('The downloaded update changed. Download it again.');
      }
      final bundle = File(Platform.resolvedExecutable).parent.parent.parent;
      if (!bundle.path.endsWith('/Relay Flutter.app')) {
        throw StateError(
          'Install Relay Flutter in Applications before updating.',
        );
      }
      final stage = await bundle.parent.createTemp('.relay-flutter-update-');
      final candidate = '${stage.path}/Relay Flutter.app';
      await command('/usr/bin/ditto', ['-x', '-k', archive!.path, stage.path]);
      await command('/usr/bin/codesign', [
        '--verify',
        '--deep',
        '--strict',
        candidate,
      ]);
      final plist = '$candidate/Contents/Info.plist';
      if ((await command('/usr/libexec/PlistBuddy', [
                '-c',
                'Print :CFBundleIdentifier',
                plist,
              ])).trim() !=
              'app.relay.flutterExperiment' ||
          (await command('/usr/libexec/PlistBuddy', [
                '-c',
                'Print :CFBundleShortVersionString',
                plist,
              ])).trim() !=
              release!['version']) {
        throw StateError(
          'The package is not the expected Relay Flutter release.',
        );
      }
      if (release!['name'] != null) {
        for (final (field, value) in [
          ('CFBundleVersion', release!['build']),
          ('RelayPreview', release!['name']),
        ]) {
          if ((await command('/usr/libexec/PlistBuddy', [
                '-c',
                'Print :$field',
                plist,
              ])).trim() !=
              value) {
            throw StateError(
              'The downloaded app does not match the selected test build.',
            );
          }
        }
      }
      final helper = File('${stage.path}/replace.sh');
      await helper.writeAsString(
        await rootBundle.loadString('assets/replace.sh'),
      );
      final identity = release!['name'] == null
          ? release!['version']
          : "${release!['version']}-${release!['build']}";
      final receipt = File('${directory.path}/launched-$identity');
      if (await receipt.exists()) await receipt.delete();
      await preserveDraft();
      await Process.start('/bin/bash', [
        helper.path,
        bundle.path,
        candidate,
        '${stage.path}/Previous.app',
        '$pid',
        receipt.path,
        '${stage.path}/Failed.app',
      ], mode: ProcessStartMode.detached);
      exit(0);
    } catch (e) {
      status = e.toString();
      installing = false;
      changed();
    }
  }

  Future<String> command(String executable, List<String> args) async {
    final result = await Process.run(executable, args);
    if (result.exitCode != 0) {
      throw StateError('Update preparation failed: ${result.stderr}');
    }
    return result.stdout as String;
  }

  @override
  void dispose() {
    closed = true;
    timer?.cancel();
    api.close();
    super.dispose();
  }
}

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({
    super.key,
    required this.updates,
    required this.busy,
    required this.install,
  });
  final AppUpdates updates;
  final bool Function() busy;
  final Future<void> Function() install;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: updates,
    builder: (context, _) => AlertDialog(
      title: const Text('Relay updates'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Installed: ${updates.installedLabel}'),
              ListTile(
                title: const Text('Stable'),
                onTap: updates.working || updates.installing
                    ? null
                    : updates.selectStable,
                trailing: const Icon(Icons.download_outlined),
              ),
              const Divider(),
              Text(
                'Test builds',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (updates.catalogError != null || updates.previews.isEmpty)
                Text(updates.catalogError ?? 'No test builds published.'),
              for (final build in updates.previews)
                ListTile(
                  title: Text(AppUpdates.label(build)),
                  subtitle: Text(
                    "${build['branch']} · ${(build['commit'] as String).substring(0, 7)}${build['dirty'] == true ? ' + local edits' : ''}",
                  ),
                  onTap: updates.working || updates.installing
                      ? null
                      : () => updates.selectPreview(build),
                ),
              const SizedBox(height: 12),
              Text(updates.status),
              if (updates.working || updates.installing) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: updates.progress),
              ],
              if (updates.progress != null)
                Text('${(updates.progress! * 100).round()}%'),
              const SizedBox(height: 12),
              const Text(
                'Downloads happen in the background. Install and restart when you are ready.',
              ),
              if (busy())
                const Text(
                  'Wait for the current response or stop it before installing.',
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: updates.installing ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: updates.working || updates.installing
              ? null
              : () async {
                  await updates.loadPreviews();
                  await updates.check();
                },
          child: const Text('Refresh'),
        ),
        FilledButton(
          onPressed:
              updates.ready &&
                  !updates.working &&
                  !updates.installing &&
                  !busy()
              ? install
              : null,
          child: const Text('Install and restart'),
        ),
      ],
    ),
  );
}
