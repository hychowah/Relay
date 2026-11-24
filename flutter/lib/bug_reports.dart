import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace_style.dart';

/// What a report is for, as the service saves it, with its label and icon.
/// Reports saved before categories existed are bugs.
const reportCategories = {
  'bug': ('Bug', Icons.bug_report_outlined),
  'feature': ('Feature request', Icons.lightbulb_outline),
  'update': ('Update request', Icons.auto_fix_high_outlined),
};

String reportCategory(Json item) =>
    reportCategories.containsKey(item['category'])
    ? item['category'] as String
    : 'bug';

/// Lists the reports saved on the service, all or one category, and shows one
/// report's description, screenshot and recorded events. Each report can be
/// marked solved or open again, moved to another category, or deleted.
class BugReportsDialog extends StatefulWidget {
  const BugReportsDialog({super.key, required this.api});
  final RelayApi api;
  @override
  State<BugReportsDialog> createState() => _BugReportsDialogState();
}

class _BugReportsDialogState extends State<BugReportsDialog> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  List<Json> reports = [];
  // The category the list shows; null shows every report.
  String? category;
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
    await widget.api.updateBugReport(id as String, {'status': status});
    for (final shown in [...reports, ?report]) {
      if (shown['id'] == id) shown['status'] = status;
    }
  });

  Future<void> move(Json item, String to) => _run(() async {
    final id = item['id'];
    await widget.api.updateBugReport(id as String, {'category': to});
    for (final shown in [...reports, ?report]) {
      if (shown['id'] == id) shown['category'] = to;
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
    tooltip: 'Delete report',
    label: 'Delete',
    onConfirmed: loading ? null : () => delete(item),
  );

  Widget _categoryButton(Json item) {
    final (label, icon) = reportCategories[reportCategory(item)]!;
    return PopupMenuButton<String>(
      tooltip: 'Change category',
      enabled: !loading,
      onSelected: (to) => move(item, to),
      itemBuilder: (_) => [
        for (final MapEntry(:key, value: (label, _))
            in reportCategories.entries)
          CheckedPopupMenuItem(
            value: key,
            checked: key == reportCategory(item),
            child: Text(label),
          ),
      ],
      child: Chip(avatar: Icon(icon, size: 16), label: Text(label)),
    );
  }

  Widget _categoryFilter() {
    Widget choice(String? key, String label, IconData? icon) {
      final count = key == null
          ? reports.length
          : reports.where((item) => reportCategory(item) == key).length;
      return ChoiceChip(
        avatar: icon == null ? null : Icon(icon, size: 16),
        label: Text('$label ($count)'),
        selected: category == key,
        onSelected: (_) => setState(() => category = key),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        choice(null, 'All', null),
        for (final MapEntry(:key, value: (label, icon))
            in reportCategories.entries)
          choice(key, label, icon),
      ],
    );
  }

  List<Json> get _shown => category == null
      ? reports
      : reports.where((item) => reportCategory(item) == category).toList();

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
      // What a Browser page saw (see assets/page_trace.js).
      'page' => [
        'Page ${event['kind']}',
        event['target'],
        if (event['x'] != null) '(${event['x']}, ${event['y']})',
      ].nonNulls.join(' · '),
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
      'page' => (Icons.web_outlined, colors.onSurfaceVariant),
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
      Align(alignment: Alignment.centerLeft, child: _categoryButton(report)),
      const SizedBox(height: 6),
      SelectableText(
        '${solved(report) ? 'Solved' : 'Open'} · '
        'File bug-reports/${report['id']}.json\n'
        'Recorded ${_time(report['startedAt'])} to ${_time(report['endedAt'])}'
        '${client['app'] == null ? '' : ' · ${client['app']}'}\n'
        'Model ${client['provider']?['mode'] ?? '?'} ${client['provider']?['model'] ?? ''}'
        '${(report['droppedEvents'] ?? 0) > 0 ? '\nOldest ${report['droppedEvents']} events were dropped.' : ''}'
        '${(report['refusedPageNotes'] ?? 0) > 0 ? '\n${report['refusedPageNotes']} page notes were refused.' : ''}',
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

  Widget _list() {
    final shown = _shown;
    return shown.isEmpty && !loading
        ? Center(
            child: Text(
              reports.isEmpty
                  ? 'No reports saved yet'
                  : 'No reports in this category',
            ),
          )
        : ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, index) {
              final item = shown[index];
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
                  '${reportCategories[reportCategory(item)]!.$1} · '
                  '${solved(item) ? 'Solved' : 'Open'} · '
                  '${_time(item['savedAt'])} · ${item['events']} events',
                ),
                trailing: _deleteButton(item),
                onTap: loading ? null : () => open(item),
              );
            },
          );
  }

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
                    tooltip: 'All reports',
                    onPressed: () => setState(() {
                      report = null;
                      screenshot = null;
                    }),
                    icon: const Icon(Icons.arrow_back),
                  ),
                Expanded(
                  child: Text(
                    report == null ? 'Reports' : 'Report',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (report == null && _shown.isNotEmpty)
                  Text(
                    '${_shown.where((item) => !solved(item)).length} open · '
                    '${_shown.where(solved).length} solved',
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
                  tooltip: 'Close reports',
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
            if (report == null && reports.isNotEmpty) _categoryFilter(),
            if (loading) const LinearProgressIndicator(),
            Expanded(child: report == null ? _list() : _report(report!)),
          ],
        ),
      ),
    ),
  );
}
