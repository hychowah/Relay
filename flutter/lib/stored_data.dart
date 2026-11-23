import 'dart:async';

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

  /// Makes a change on the server, then shows what it left. Answers how many
  /// items the change would delete when the server wants that agreed first:
  /// nothing was changed then, and the row keeps what the user typed.
  Future<int> _change(Future<int> Function() change) async {
    try {
      final older = await change();
      if (mounted) setState(() => error = null);
      if (older > 0) return older;
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    await _load();
    return 0;
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
            onClear: () => _change(() async {
              await widget.api.clearStoredData(kind['id'] as String);
              return 0;
            }),
            onAutoClean: (days, {deleteOlder = false}) => _change(
              () => widget.api.setAutoClean(
                kind['id'] as String,
                days,
                deleteOlder: deleteOlder,
              ),
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

  /// Saves the period; answers how many items it would delete now when that
  /// needs [deleteOlder] first.
  final Future<int> Function(int? days, {bool deleteOlder}) onAutoClean;
  @override
  State<_StoredKind> createState() => _StoredKindState();
}

class _StoredKindState extends State<_StoredKind> {
  late final int? saved = widget.kind['autoCleanDays'] as int?;
  late bool on = saved != null;
  // Nothing is sent while the user types: a period takes effect with Save.
  late final days = TextEditingController(text: '${saved ?? 30}');
  // The items a typed period would delete now, shown until the user agrees
  // or changes the period. A click just after it shows is ignored, so a
  // double-click on Save does not delete.
  int? older;
  Timer? settling;

  @override
  void dispose() {
    settling?.cancel();
    days.dispose();
    super.dispose();
  }

  int? get _typed {
    final typed = int.tryParse(days.text);
    return typed != null && typed >= 1 ? typed : null;
  }

  Future<void> _save({bool deleteOlder = false}) async {
    final typed = _typed;
    if (typed == null) return;
    final wouldDelete = await widget.onAutoClean(
      typed,
      deleteOlder: deleteOlder,
    );
    if (!mounted || wouldDelete == 0) return;
    settling?.cancel();
    settling = Timer(const Duration(milliseconds: 400), () {});
    setState(() => older = wouldDelete);
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind, colors = Theme.of(context).colorScheme;
    final name = kind['name'] as String, items = kind['items'] as int;
    final agree = older;
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
            spacing: 8,
            children: [
              Switch(
                value: on,
                // Turning it off deletes nothing, so it is saved at once;
                // turning it on only shows the period to save.
                onChanged: (value) {
                  setState(() {
                    on = value;
                    older = null;
                  });
                  if (!value && saved != null) widget.onAutoClean(null);
                },
              ),
              if (!on)
                const Text('Auto-clean is off: kept until you clear it')
              else ...[
                const Text('Auto-clean items older than'),
                SizedBox(
                  width: 58,
                  child: TextField(
                    controller: days,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(isDense: true),
                    onChanged: (_) => setState(() => older = null),
                    onSubmitted: (_) => _save(),
                  ),
                ),
                const Text('days'),
                if (agree != null)
                  TapRegion(
                    onTapOutside: (_) => setState(() => older = null),
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: colors.error,
                        foregroundColor: colors.onError,
                      ),
                      onPressed: () {
                        if (settling?.isActive ?? false) return;
                        _save(deleteOlder: true);
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(
                        'Delete $agree older ${agree == 1 ? 'item' : 'items'}',
                      ),
                    ),
                  )
                else if (_typed != saved)
                  FilledButton.tonal(
                    onPressed: _typed == null ? null : _save,
                    child: const Text('Save'),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
