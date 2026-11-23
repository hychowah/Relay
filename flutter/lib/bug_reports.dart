import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace_style.dart';

/// Lists the bug reports saved on the service and shows one report's
/// description, screenshot and recorded events. Each report can be marked
/// solved or open again, or deleted.
class BugReportsDialog extends StatefulWidget {
  const BugReportsDialog({super.key, required this.api});
  final RelayApi api;
  @override
  State<BugReportsDialog> createState() => _BugReportsDialogState();
}

class _BugReportsDialogState extends State<BugReportsDialog> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  List<Json> reports = [];
  Json? report;
  Uint8List? screenshot;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await task();
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> load() => _run(() async {
    reports = await widget.api.bugReports();
  });

  Future<void> open(Json item) => _run(() async {
    final id = item['id'] as String;
    final opened = await widget.api.bugReport(id);
    Uint8List? picture;
    if (item['screenshot'] == true) {
      try {
        picture = await widget.api.bugReportScreenshot(id);
      } catch (_) {
        /* The events are still readable without the picture. */
      }
    }
    report = opened;
    screenshot = picture;
  });

  static bool solved(Json item) => item['status'] == 'solved';

  Future<void> toggleSolved(Json item) => _run(() async {
    final id = item['id'];
    final status = solved(item) ? 'open' : 'solved';
    await widget.api.setBugReportStatus(id as String, status);
    for (final shown in [...reports, ?report]) {
      if (shown['id'] == id) shown['status'] = status;
    }
  });

  Future<void> delete(Json item) async {
    await _run(() async {
      final id = item['id'];
      await widget.api.deleteBugReport(id as String);
      reports.removeWhere((shown) => shown['id'] == id);
      if (report?['id'] == id) {
        report = null;
        screenshot = null;
      }
    });
  }

  Widget _solvedButton(Json item) => IconButton(
    tooltip: solved(item) ? 'Mark open' : 'Mark solved',
    onPressed: loading ? null : () => toggleSolved(item),
    icon: solved(item)
        ? const Icon(Icons.check_circle, color: Colors.green)
        : Icon(Icons.radio_button_unchecked, color: colors.onSurfaceVariant),
  );

  Widget _deleteButton(Json item) => ConfirmDeleteButton(
    tooltip: 'Delete bug report',
    label: 'Delete',
    onConfirmed: loading ? null : () => delete(item),
  );

  static String _time(Object? iso) {
    final time = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (time == null) return '';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  static String summary(Json event) {
    final command = event['command'] as Json?;
    return switch (event['type']) {
      'action' => [
        event['name'],
        event['tab'] ??
            event['appId'] ??
            event['text'] ??
            event['address'] ??
            event['item'],
      ].nonNulls.join(' · '),
      'request' =>
        '${event['method']} ${event['path']} → '
            '${event['status'] ?? event['failure'] ?? '?'} (${event['ms']} ms)',
      'error' => '${event['message']}',
      'agent view command' =>
        'Agent ${command?['kind']} in ${command?['appId'] ?? command?['source']?['appId']}',
      _ => '${event['type']}',
    };
  }

  static String _pretty(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  // The window picture is too small to read inside the report.
  void _showScreenshot(Uint8List picture) => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 4,
              child: Center(child: Image.memory(picture)),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton.filledTonal(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _details(String title, Object? value) => ExpansionTile(
    title: Text(title),
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 12),
    expandedAlignment: Alignment.centerLeft,
    children: [
      SelectableText(
        _pretty(value),
        style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
      ),
    ],
  );

  Widget _event(Json event, DateTime? start) {
    final at = DateTime.tryParse('${event['at']}');
    final offset = start == null || at == null
        ? ''
        : '+${(at.difference(start).inMilliseconds / 1000).toStringAsFixed(1)}s';
    final (icon, color) = switch (event['type']) {
      'action' => (Icons.touch_app_outlined, colors.primary),
      'request' =>
        (event['status'] ?? 500) >= 400 || event['failure'] != null
            ? (Icons.swap_vert, Colors.red)
            : (Icons.swap_vert, colors.onSurfaceVariant),
      'error' => (Icons.error_outline, Colors.red),
      _ => (Icons.smart_toy_outlined, colors.onSurface),
    };
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      leading: Icon(icon, size: 17, color: color),
      title: Text(summary(event), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(offset),
      expandedAlignment: Alignment.centerLeft,
      childrenPadding: const EdgeInsets.only(left: 40, bottom: 10),
      children: [
        SelectableText(
          _pretty(event),
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 11),
        ),
      ],
    );
  }

  Widget _report(Json report) {
    final events = ((report['events'] as List?) ?? []).cast<Json>();
    final start = DateTime.tryParse('${report['startedAt']}');
    final client = (report['client'] as Json?) ?? {};
    final header = <Widget>[
      SelectableText(
        report['description'] as String? ?? '',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      SelectableText(
        '${solved(report) ? 'Solved' : 'Open'} · '
        'File bug-reports/${report['id']}.json\n'
        'Recorded ${_time(report['startedAt'])} to ${_time(report['endedAt'])}'
        '${client['app'] == null ? '' : ' · ${client['app']}'}\n'
        'Model ${client['provider']?['mode'] ?? '?'} ${client['provider']?['model'] ?? ''}'
        '${(report['droppedEvents'] ?? 0) > 0 ? '\nOldest ${report['droppedEvents']} events were dropped.' : ''}',
        style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
      ),
      if (screenshot != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: 'Open the screenshot full size',
              child: InkWell(
                onTap: () => _showScreenshot(screenshot!),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: Image.memory(screenshot!),
                ),
              ),
            ),
          ),
        ),
      _details('Workspace when saved', report['workspace']),
      _details('Server conversation record', report['serverConversation']),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'Events (${events.length})',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
    ];
    return ListView.builder(
      itemCount: header.length + events.length,
      itemBuilder: (context, index) => index < header.length
          ? header[index]
          : _event(events[index - header.length], start),
    );
  }

  Widget _list() => reports.isEmpty && !loading
      ? const Center(child: Text('No bug reports saved yet'))
      : ListView.builder(
          itemCount: reports.length,
          itemBuilder: (context, index) {
            final item = reports[index];
            final description = item['description'] as String? ?? '';
            return ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              leading: _solvedButton(item),
              title: Text(
                description.isEmpty ? 'No description' : description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: solved(item)
                    ? TextStyle(color: colors.onSurfaceVariant)
                    : null,
              ),
              subtitle: Text(
                '${solved(item) ? 'Solved' : 'Open'} · '
                '${_time(item['savedAt'])} · ${item['events']} events',
              ),
              trailing: _deleteButton(item),
              onTap: loading ? null : () => open(item),
            );
          },
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
                if (report != null)
                  IconButton(
                    tooltip: 'All bug reports',
                    onPressed: () => setState(() {
                      report = null;
                      screenshot = null;
                    }),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Text(
                    report == null ? 'Bug reports' : 'Bug report',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (report == null && reports.isNotEmpty)
                  Text(
                    '${reports.where((item) => !solved(item)).length} open · '
                    '${reports.where(solved).length} solved',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                if (report != null) ...[
                  _solvedButton(report!),
                  _deleteButton(report!),
                ],
                if (report == null)
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: loading ? null : load,
                    icon: const Icon(Icons.refresh),
                  ),
                IconButton(
                  tooltip: 'Close bug reports',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (error != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(onPressed: load, child: const Text('Retry')),
                ],
              ),
            if (loading) const LinearProgressIndicator(),
            Expanded(child: report == null ? _list() : _report(report!)),
          ],
        ),
      ),
    ),
  );
}
