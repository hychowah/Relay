import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace_dialogs.dart';
import 'workspace_style.dart';

/// The folders on the Relay server's machine that the agent may read and
/// search, read-only, through the Files app. The server checks each path and
/// enforces the access rules; this dialog only edits the list.
class SharedFoldersDialog extends StatefulWidget {
  const SharedFoldersDialog({super.key, required this.api});
  final RelayApi api;
  @override
  State<SharedFoldersDialog> createState() => _SharedFoldersDialogState();
}

class _SharedFoldersDialogState extends State<SharedFoldersDialog> {
  final path = TextEditingController();
  List<String>? folders;
  String? error;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    _change(widget.api.sharedFolders);
  }

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  Future<bool> _change(Future<List<String>> Function() change) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final next = await change();
      if (mounted) setState(() => folders = next);
      return true;
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _add() async {
    final typed = path.text.trim();
    if (typed.isEmpty) return;
    if (await _change(() => widget.api.addSharedFolder(typed))) path.clear();
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    title: 'Shared folders',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 14,
      children: [
        const Text(
          'The agent can read and search these folders on the computer '
          'that runs Relay, but not change them. It reads plain text files '
          'and PDFs; other files show by name only. Hidden files inside a '
          'folder are left out. Text it reads is sent to your model '
          'provider. A bot uses them only '
          'when Files is one of its apps.',
        ),
        Row(
          spacing: 10,
          children: [
            Expanded(
              child: TextField(
                controller: path,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Folder path',
                  hintText: '/home/you/notes',
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            FilledButton(
              onPressed: saving ? null : _add,
              child: const Text('Add'),
            ),
          ],
        ),
        if (folders == null && error == null) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (folders?.isEmpty ?? false) const Text('No folders are shared.'),
        for (final folder in folders ?? const <String>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder),
            trailing: ConfirmDeleteButton(
              tooltip: 'Stop sharing',
              label: 'Remove',
              onConfirmed: saving
                  ? null
                  : () => _change(() => widget.api.removeSharedFolder(folder)),
            ),
          ),
      ],
    ),
  );
}
