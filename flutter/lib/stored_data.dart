import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace_dialogs.dart';
import 'workspace_style.dart';

/// A size as people read it: 0 B, 812 B, 3.4 KB, 12 MB.
String dataSize(int bytes) {
  if (bytes < 1000) return '$bytes B';
  var size = bytes / 1000;
  for (final unit in ['KB', 'MB']) {
    if (size < 1000) {
      return '${size < 10 ? size.toStringAsFixed(1) : size.round()} $unit';
    }
    size /= 1000;
  }
  return '${size < 10 ? size.toStringAsFixed(1) : size.round()} GB';
}

/// What the Relay server keeps as the user works, such as browsing history
/// and highlights: each kind with its size, a clear button and an optional
/// auto-clean of items older than a number of days. The server owns the list,
/// so a new kind of data appears here without a client change.
class StoredDataDialog extends StatefulWidget {
  const StoredDataDialog({super.key, required this.api});
  final RelayApi api;
  @override
  State<StoredDataDialog> createState() => _StoredDataDialogState();
}

class _StoredDataDialogState extends State<StoredDataDialog> {
  List<Json>? kinds;
  String? error;
  int loads = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await widget.api.storedData();
      if (mounted) {
        setState(() {
          kinds = loaded;
          loads++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  /// Makes a change on the server, then shows what it left.
  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    title: 'Stored data',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 14,
      children: [
        const Text('Kept on the Relay server, for every device that uses it.'),
        if (kinds == null && error == null) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        for (final kind in kinds ?? const <Json>[])
          _StoredKind(
            // Each load starts the rows afresh with the saved days, also
            // after the server refused a change.
            key: ValueKey('${kind['id']} $loads'),
            kind: kind,
            onClear: () =>
                _change(() => widget.api.clearStoredData(kind['id'] as String)),
            onAutoClean: (days) => _change(
              () => widget.api.setAutoClean(kind['id'] as String, days),
            ),
          ),
      ],
    ),
  );
}

class _StoredKind extends StatefulWidget {
  const _StoredKind({
    super.key,
    required this.kind,
    required this.onClear,
    required this.onAutoClean,
  });
  final Json kind;
  final VoidCallback onClear;
  final void Function(int? days) onAutoClean;
  @override
  State<_StoredKind> createState() => _StoredKindState();
}

class _StoredKindState extends State<_StoredKind> {
  // Auto-clean first turned on keeps a month, until the user types another.
  late final days = TextEditingController(
    text: '${widget.kind['autoCleanDays'] ?? 30}',
  );

  @override
  void dispose() {
    days.dispose();
    super.dispose();
  }

  // The period last sent, so leaving the field after Enter saves it once.
  late Object? sent = widget.kind['autoCleanDays'];

  void _saveDays() {
    final typed = int.tryParse(days.text);
    if (typed == null || typed < 1 || typed == sent) return;
    sent = typed;
    widget.onAutoClean(typed);
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind, colors = Theme.of(context).colorScheme;
    final name = kind['name'] as String, items = kind['items'] as int;
    final auto = kind['autoCleanDays'] != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${items == 1 ? '1 item' : '$items items'} · '
                '${dataSize(kind['bytes'] as int)}',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
              const SizedBox(width: 6),
              ConfirmDeleteButton(
                tooltip: 'Clear ${name.toLowerCase()}',
                label: 'Clear',
                onConfirmed: items == 0 ? null : widget.onClear,
              ),
            ],
          ),
          Text(
            kind['description'] as String,
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          // Wraps on a narrow screen.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Switch(
                value: auto,
                onChanged: (on) => widget.onAutoClean(
                  on ? (int.tryParse(days.text) ?? 30).clamp(1, 3650) : null,
                ),
              ),
              const SizedBox(width: 8),
              if (!auto)
                const Text('Auto-clean is off: kept until you clear it')
              else ...[
                const Text('Auto-clean items older than'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 58,
                  child: Focus(
                    onFocusChange: (focused) {
                      if (!focused) _saveDays();
                    },
                    child: TextField(
                      controller: days,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      decoration: const InputDecoration(isDense: true),
                      onSubmitted: (_) => _saveDays(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('days'),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
