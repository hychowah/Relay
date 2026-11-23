import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';

/// How often an open App servers screen reads the servers' state again.
const appServersRefresh = Duration(seconds: 3);

/// How often shown logs are read again; Refresh reads them at once.
const appServerLogsRefresh = Duration(seconds: 10);

bool _up(Json server) =>
    server['state'] == 'running' || server['state'] == 'starting';

/// The servers the host's servers file names: each one's state, Start, Stop
/// and Restart, whether it starts with the computer, and its recent logs.
/// Servers are set up only in that file, never here.
class AppServersDialog extends StatefulWidget {
  const AppServersDialog({super.key, required this.api});
  final RelayApi api;
  @override
  State<AppServersDialog> createState() => _AppServersDialogState();
}

class _AppServersDialogState extends State<AppServersDialog> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  List<Json>? servers;
  final busy = <String>{};
  // A failed change stays until the next change; a failed list or logs read
  // until the next read of the same kind.
  String? error, readError, logsError;
  Json? logsFor;
  String? logs;
  Timer? timer, logsTimer;
  // A timer tick is skipped while any read of its kind is running.
  int listing = 0, readingLogs = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
    timer = Timer.periodic(appServersRefresh, (_) {
      if (listing == 0) unawaited(load());
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    logsTimer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    listing++;
    try {
      final loaded = await widget.api.appServers();
      if (!mounted) return;
      setState(() {
        servers = loaded;
        readError = null;
      });
    } on RelayApiException catch (e) {
      // An older backend has no such route; asking again will not help.
      if (e.status == 404) timer?.cancel();
      if (mounted) {
        setState(
          () => readError = e.status == 404
              ? 'This Relay backend does not offer app servers yet.'
              : e.toString(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => readError = e.toString());
    } finally {
      listing--;
    }
  }

  /// Runs one change on a server; a failure stays on screen until the next.
  Future<void> change(Json server, Future<void> Function() task) async {
    final id = server['id'] as String;
    setState(() {
      busy.add(id);
      error = null;
    });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => error = '${server['name']}: $e');
    }
    await load();
    if (mounted) setState(() => busy.remove(id));
  }

  Future<void> loadLogs() async {
    final shown = logsFor;
    if (shown == null) return;
    readingLogs++;
    try {
      final text = await widget.api.appServerLogs(shown['id'] as String);
      if (mounted && shown == logsFor) {
        setState(() {
          logs = text;
          logsError = null;
        });
      }
    } catch (e) {
      if (mounted && shown == logsFor) setState(() => logsError = e.toString());
    } finally {
      readingLogs--;
    }
  }

  void showLogs(Json? server) {
    logsTimer?.cancel();
    setState(() {
      logsFor = server;
      logs = null;
      logsError = null;
    });
    if (server == null) return;
    unawaited(loadLogs());
    logsTimer = Timer.periodic(appServerLogsRefresh, (_) {
      if (readingLogs == 0) unawaited(loadLogs());
    });
  }

  Widget _stateIcon(String? state) => switch (state) {
    'running' => const Icon(Icons.circle, size: 12, color: Colors.green),
    'failed' => Icon(Icons.error, size: 16, color: colors.error),
    'starting' ||
    'stopping' => const Icon(Icons.timelapse, size: 16, color: Colors.orange),
    _ => Icon(Icons.circle_outlined, size: 12, color: colors.onSurfaceVariant),
  };

  static String _label(Object? state) => switch (state) {
    'running' => 'Running',
    'starting' => 'Starting',
    'stopping' => 'Stopping',
    'failed' => 'Failed',
    _ => 'Stopped',
  };

  Widget _server(Json server) {
    final id = server['id'] as String;
    final working = busy.contains(id);
    final autoStart = server['autoStart'] as bool?;
    final detail = server['detail'] as String?;
    void act(String action) =>
        change(server, () => widget.api.controlAppServer(id, action));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          Row(
            spacing: 10,
            children: [
              SizedBox(
                width: 18,
                child: _stateIcon(server['state'] as String?),
              ),
              Expanded(
                child: Text(
                  server['name'] as String,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                _label(server['state']),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(detail, style: TextStyle(color: colors.error)),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                if (!_up(server))
                  TextButton.icon(
                    onPressed: working ? null : () => act('start'),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start'),
                  ),
                if (_up(server))
                  TextButton.icon(
                    onPressed: working ? null : () => act('stop'),
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('Stop'),
                  ),
                if (_up(server))
                  TextButton.icon(
                    onPressed: working ? null : () => act('restart'),
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: const Text('Restart'),
                  ),
                TextButton.icon(
                  onPressed: () => showLogs(server),
                  icon: const Icon(Icons.notes_rounded),
                  label: const Text('Logs'),
                ),
                Tooltip(
                  message: server['autoStartNote'] as String? ?? '',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: autoStart ?? false,
                        onChanged: autoStart == null || working
                            ? null
                            : (on) => change(
                                server,
                                () => widget.api.setAppServerAutoStart(id, on),
                              ),
                      ),
                      Text(
                        autoStart == null
                            ? 'Start with the computer: not available'
                            : 'Start with the computer',
                        style: autoStart == null
                            ? TextStyle(color: colors.onSurfaceVariant)
                            : null,
                      ),
                    ],
                  ),
                ),
                if (working)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    final list = servers;
    if (list == null) {
      // A list that could not be read shows only the reason above.
      return readError == null
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          'No app servers are set up. They are named in the servers file '
          'on the computer that runs Relay.',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, index) => _server(list[index]),
    );
  }

  // A failed refresh keeps the logs already shown.
  Widget _logs() => logs == null
      ? Center(
          child: logsError == null
              ? const CircularProgressIndicator()
              : Text(logsError!, style: TextStyle(color: colors.error)),
        )
      : SingleChildScrollView(
          reverse: true,
          child: SizedBox(
            width: double.infinity,
            child: SelectableText(
              logs!.trim().isEmpty ? 'No log lines yet.' : logs!,
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
            ),
          ),
        );

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 760,
      height: MediaQuery.sizeOf(context).height * .85,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          spacing: 12,
          children: [
            Row(
              children: [
                if (logsFor != null)
                  IconButton(
                    tooltip: 'All app servers',
                    onPressed: () => showLogs(null),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Text(
                    logsFor == null
                        ? 'App servers'
                        : 'Logs: ${logsFor!['name']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (logsFor != null)
                  IconButton(
                    tooltip: 'Refresh logs',
                    onPressed: loadLogs,
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  tooltip: 'Close app servers',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            for (final message in [?error, ?readError])
              Text(message, style: TextStyle(color: colors.error)),
            Expanded(child: logsFor == null ? _list() : _logs()),
          ],
        ),
      ),
    ),
  );
}
