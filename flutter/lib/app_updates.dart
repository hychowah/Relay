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
    this.bundle,
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

  /// The running app, whose unchanged files an update reuses.
  final Directory? bundle;
  Map<String, String>? _installed;
  Directory get _store => Directory('${directory.path}/files');
  File _stored(Json entry) => File('${_store.path}/${entry['sha256']}');
  Timer? timer;
  Json? release;

  /// The verified download for [release]: its ZIP, or its list of files.
  File? download;
  String status = 'No update checked yet';
  double? progress;
  bool working = false, installing = false, closed = false;
  bool get ready => download != null;
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
      bundle: File(Platform.resolvedExecutable).parent.parent.parent,
    );
    await updates.directory.create(recursive: true);
    final identity = updates.previewName.isEmpty
        ? info.version
        : '${info.version}-${info.buildNumber}';
    final receipt = 'launched-$identity';
    await File('${updates.directory.path}/$receipt').writeAsString('ready');
    await updates.discardInstallLeftovers(receipt, updates.bundle!);
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
  Future<void> _discardDownloads({Set<String> keep = const {}}) async {
    try {
      final stale = [
        await for (final entry in directory.list(recursive: true))
          if (entry is File &&
              !keep.contains(entry.path) &&
              (entry.path.startsWith('${_store.path}/') ||
                  entry.path.endsWith('.zip') ||
                  entry.path.endsWith('.part')))
            entry,
      ];
      for (final file in stale) {
        await file.delete();
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
    final list = raw['fileList'];
    if (version is! String ||
        (list != null &&
            (list is! Json ||
                list['sha256'] is! String ||
                !_hash.hasMatch(list['sha256'] as String) ||
                list['size'] is! int ||
                list['packed'] is! int)) ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        hash is! String ||
        !_hash.hasMatch(hash) ||
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

  static final _hash = RegExp(r'^[a-f0-9]{64}$');

  /// A release's file list: each entry is a file with its `sha256`, `size`,
  /// compressed `packed` size and `exec` flag, or a symlink with its `link`.
  /// Paths are relative to the app bundle.
  static List<Json> _entries(String text) {
    final entries = (jsonDecode(text) as List).cast<Json>();
    for (final entry in entries) {
      final path = entry['path'] as String, hash = entry['sha256'];
      if (path.startsWith('/') ||
          path.split('/').contains('..') ||
          (hash != null && !_hash.hasMatch(hash as String))) {
        throw StateError('The published update is incomplete.');
      }
    }
    return entries;
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
      download = null;
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
      download = null;
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
      await directory.create(recursive: true);
      final Set<String> keep;
      if (data['fileList'] == null) {
        final destination = File('${directory.path}/${data['file']}');
        if (!await verified(destination, data)) {
          status = 'Downloading ${label(data)}…';
          progress = 0;
          await _fetch(
            data['file'] as String,
            data,
            destination,
            (bytes) => progress = bytes / (data['size'] as int),
          );
        }
        download = destination;
        keep = {destination.path};
      } else {
        keep = await _downloadFiles(data);
      }
      await _discardDownloads(keep: keep);
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

  /// Downloads only the files of [data]'s app that neither the running app
  /// nor an earlier download has, and returns the downloads it uses. Finished
  /// files stay, so an interrupted download continues with the rest.
  Future<Set<String>> _downloadFiles(Json data) async {
    await _store.create(recursive: true);
    final list = data['fileList'] as Json;
    if (!await verified(_stored(list), list)) {
      await _fetch('files/${list['sha256']}.gz', list, _stored(list), (_) {});
    }
    final entries = _entries(await _stored(list).readAsString());
    _installed ??= await _hashInstalled();
    final missing = <String, Json>{};
    for (final entry in entries) {
      final hash = entry['sha256'];
      if (hash == null ||
          _installed!.containsKey(hash) ||
          missing.containsKey(hash)) {
        continue;
      }
      if (!await verified(_stored(entry), entry)) missing[hash] = entry;
    }
    if (missing.isNotEmpty) {
      final total = missing.values.fold(
        0,
        (sum, e) => sum + (e['packed'] as int),
      );
      status =
          'Downloading ${label(data)}: ${_megabytes(total)} of the ${_megabytes(data['size'] as int)} package…';
      progress = 0;
      var done = 0;
      for (final entry in missing.values) {
        await _fetch(
          'files/${entry['sha256']}.gz',
          entry,
          _stored(entry),
          (bytes) => progress = (done + bytes) / total,
        );
        done += entry['packed'] as int;
      }
    }
    download = _stored(list);
    return {
      download!.path,
      for (final entry in entries)
        if (entry['sha256'] != null) _stored(entry).path,
    };
  }

  static String _megabytes(int bytes) =>
      '${(bytes / 1e6).toStringAsFixed(1)} MB';

  /// The running app's files by SHA-256.
  Future<Map<String, String>> _hashInstalled() async {
    final files = <String, String>{};
    if (bundle == null || !await bundle!.exists()) return files;
    await for (final entry in bundle!.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is File) {
        files[(await sha256.bind(entry.openRead()).first).toString()] =
            entry.path;
      }
    }
    return files;
  }

  /// Downloads [file] to [destination], reporting the bytes received so far,
  /// and checks it against [data]'s size and SHA-256. A stored `.gz` file is
  /// limited by its compressed `packed` size and checked once uncompressed.
  Future<void> _fetch(
    String file,
    Json data,
    File destination,
    void Function(int bytes) received,
  ) async {
    changed();
    final limit = (data['packed'] ?? data['size']) as int;
    final response = await api.updateArchive(file);
    if (response.statusCode != 200) {
      throw StateError('The update could not be downloaded.');
    }
    final partial = File('${destination.path}.part');
    final sink = partial.openWrite();
    var bytes = 0;
    try {
      final stream = response.stream.timeout(const Duration(seconds: 30)).map((
        chunk,
      ) {
        bytes += chunk.length;
        if (bytes > limit) throw StateError('Unexpected update size.');
        received(bytes);
        changed();
        return chunk;
      });
      await for (final chunk
          in file.endsWith('.gz') ? stream.transform(gzip.decoder) : stream) {
        sink.add(chunk);
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
      final files = release!['fileList'] != null;
      if (!await verified(
        download!,
        files ? release!['fileList'] as Json : release!,
      )) {
        throw StateError(_changed);
      }
      final bundle = this.bundle;
      if (bundle == null || !bundle.path.endsWith('/Relay Flutter.app')) {
        throw StateError(
          'Install Relay Flutter in Applications before updating.',
        );
      }
      final stage = await bundle.parent.createTemp('.relay-flutter-update-');
      final candidate = '${stage.path}/Relay Flutter.app';
      if (files) {
        await assemble(candidate);
      } else {
        await command('/usr/bin/ditto', [
          '-x',
          '-k',
          download!.path,
          stage.path,
        ]);
      }
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

  static const _changed = 'The downloaded update changed. Download it again.';

  /// Builds the ready release's app at [app] from the downloaded files and the
  /// running app's unchanged ones, checking each copy against the file list.
  Future<void> assemble(String app) async {
    final entries = _entries(await download!.readAsString());
    final executables = <String>[];
    // Files first, so that no copy can write through a symlink.
    for (final entry in entries.where((entry) => entry['link'] == null)) {
      final target = File('$app/${entry['path']}');
      await target.parent.create(recursive: true);
      final stored = _stored(entry);
      final source = await stored.exists()
          ? stored
          : File(_installed?[entry['sha256']] ?? stored.path);
      await source.openRead().pipe(target.openWrite());
      if (!await verified(target, entry)) throw StateError(_changed);
      if (entry['exec'] == true) executables.add(target.path);
    }
    for (final entry in entries.where((entry) => entry['link'] != null)) {
      final link = Link('$app/${entry['path']}');
      await link.parent.create(recursive: true);
      await link.create(entry['link'] as String);
    }
    if (executables.isNotEmpty) {
      await command('/bin/chmod', ['755', ...executables]);
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
