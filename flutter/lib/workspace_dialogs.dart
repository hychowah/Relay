import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace.dart';
import 'workspace_style.dart';

class WorkspaceDialog extends StatelessWidget {
  const WorkspaceDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
  });
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(title),
    content: SizedBox(width: 520, child: SingleChildScrollView(child: child)),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      ...actions,
    ],
  );
}

Future<void> showBots(
  BuildContext context,
  Workspace w,
  VoidCallback selected,
) async {
  await w.loadBots();
  await w.refreshApps();
  if (!context.mounted) return;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => WorkspaceDialog(
        title: 'Bots',
        actions: [
          FilledButton(
            onPressed: () async {
              await showDialog<void>(
                context: context,
                builder: (_) => BotEditor(workspace: w),
              );
              if (context.mounted) update(() {});
            },
            child: const Text('Create bot'),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            if (error != null) Text(error!),
            ListTile(
              title: const Text('Personal chat'),
              selected: w.selectedBotId == null,
              onTap: () async {
                try {
                  await w.newConversation(botId: null, changeBot: true);
                  if (context.mounted) {
                    selected();
                    Navigator.pop(context);
                  }
                } catch (e) {
                  if (context.mounted) update(() => error = e.toString());
                }
              },
            ),
            ...w.bots.map(
              (bot) => ListTile(
                title: Text(bot['name'] as String),
                subtitle: Text(bot['objective'] as String, maxLines: 2),
                selected: bot['id'] == w.selectedBotId,
                trailing: IconButton(
                  tooltip: 'Edit bot',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => BotEditor(workspace: w, bot: bot),
                    );
                    if (context.mounted) update(() {});
                  },
                ),
                onTap: () async {
                  try {
                    await w.newConversation(
                      botId: bot['id'] as String,
                      changeBot: true,
                    );
                    if (context.mounted) {
                      selected();
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (context.mounted) update(() => error = e.toString());
                  }
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class BotEditor extends StatefulWidget {
  const BotEditor({super.key, required this.workspace, this.bot});
  final Workspace workspace;
  final Json? bot;
  @override
  State<BotEditor> createState() => _BotEditorState();
}

class _BotEditorState extends State<BotEditor> {
  late final name = TextEditingController(
    text: widget.bot?['name'] as String? ?? '',
  );
  late final objective = TextEditingController(
    text: widget.bot?['objective'] as String? ?? '',
  );
  late final scope = TextEditingController(
    text: widget.bot?['scope'] as String? ?? '',
  );
  late final appIds = Set<String>.from(
    widget.bot?['appIds'] as List? ??
        widget.workspace.apps.map((a) => a.id).toList(),
  );
  String? error;
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    objective.dispose();
    scope.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.workspace.api.saveBot(widget.bot?['id'] as String?, {
        'name': name.text,
        'objective': objective.text,
        'scope': scope.text,
        // Save what the checkboxes show: an app no longer registered is dropped.
        'appIds': [
          for (final app in widget.workspace.apps)
            if (appIds.contains(app.id)) app.id,
        ],
      });
      await widget.workspace.loadBots();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    title: widget.bot == null ? 'Create bot' : 'Edit bot',
    actions: [
      FilledButton(
        onPressed: saving ? null : save,
        child: const Text('Save bot'),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        TextField(
          controller: objective,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Objective'),
        ),
        TextField(
          controller: scope,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Scope'),
        ),
        const SizedBox(height: 12),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text('Allowed apps'),
        ),
        ...widget.workspace.apps.map(
          (app) => CheckboxListTile(
            title: Text(app.name),
            value: appIds.contains(app.id),
            onChanged: saving
                ? null
                : (value) => setState(() {
                    value == true ? appIds.add(app.id) : appIds.remove(app.id);
                  }),
          ),
        ),
        if (error != null) Text(error!),
      ],
    ),
  );
}

class MemoryDialog extends StatefulWidget {
  const MemoryDialog({
    super.key,
    required this.workspace,
    required this.onSelected,
  });
  final Workspace workspace;
  final VoidCallback onSelected;
  @override
  State<MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<MemoryDialog> {
  List<Json> entries = [];
  String? botId, error;
  bool loading = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    final scope = botId;
    try {
      final result = await widget.workspace.api.memories(scope);
      if (mounted && botId == scope) setState(() => entries = result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted && botId == scope) setState(() => loading = false);
    }
  }

  Future<void> edit([Json? entry]) async {
    await showDialog<void>(
      context: context,
      builder: (_) =>
          MemoryEditor(api: widget.workspace.api, botId: botId, entry: entry),
    );
    if (mounted) await load();
  }

  Future<void> forget(Json entry) async {
    try {
      await widget.workspace.api.forgetMemory(entry['id'] as String);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    title: 'Memory',
    actions: [
      FilledButton(
        onPressed: loading ? null : () => edit(),
        child: const Text('Add memory'),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        DropdownButtonFormField<String>(
          initialValue: botId ?? '',
          decoration: const InputDecoration(labelText: 'Scope'),
          items: [
            const DropdownMenuItem(
              value: '',
              child: Text('Shared preferences'),
            ),
            ...widget.workspace.bots.map(
              (bot) => DropdownMenuItem(
                value: bot['id'] as String,
                child: Text(bot['name'] as String),
              ),
            ),
          ],
          onChanged: (value) {
            botId = value == '' ? null : value;
            load();
          },
        ),
        if (loading) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        if (entries.isEmpty && !loading)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('No memories yet'),
          ),
        ...entries.map(
          (entry) => Column(
            children: [
              ListTile(
                title: Text(entry['key'] as String),
                subtitle: Text(entry['content'] as String),
                onTap: () => edit(entry),
                trailing: ConfirmDeleteButton(
                  tooltip: 'Forget memory',
                  label: 'Forget',
                  onConfirmed: () => forget(entry),
                ),
              ),
              if (entry['sourceConversationId'] != null)
                TextButton(
                  onPressed: () async {
                    try {
                      await widget.workspace.selectConversation(
                        entry['sourceConversationId'] as String,
                      );
                      if (context.mounted) {
                        widget.onSelected();
                        Navigator.pop(context);
                      }
                    } catch (e) {
                      if (mounted) setState(() => error = e.toString());
                    }
                  },
                  child: const Text('Open source conversation'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ForwardDialog extends StatefulWidget {
  const ForwardDialog({
    super.key,
    required this.workspace,
    required this.onSelected,
  });
  final Workspace workspace;
  final VoidCallback onSelected;
  @override
  State<ForwardDialog> createState() => _ForwardDialogState();
}

class _ForwardDialogState extends State<ForwardDialog> {
  final note = TextEditingController();
  String? botId, error;
  bool saving = false;
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> forward() async {
    setState(() => saving = true);
    try {
      final next = await widget.workspace.api.forwardConversation(
        widget.workspace.conversationId!,
        {'botId': botId, 'note': note.text},
      );
      await widget.workspace.selectConversation(next);
      if (mounted) {
        widget.onSelected();
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    title: 'Forward conversation',
    actions: [
      FilledButton(
        onPressed: saving || botId == null || widget.workspace.busy
            ? null
            : forward,
        child: const Text('Forward'),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        DropdownButtonFormField<String>(
          decoration: const InputDecoration(labelText: 'Bot'),
          items: widget.workspace.bots
              .map(
                (bot) => DropdownMenuItem(
                  value: bot['id'] as String,
                  child: Text(bot['name'] as String),
                ),
              )
              .toList(),
          onChanged: saving ? null : (value) => setState(() => botId = value),
        ),
        TextField(
          controller: note,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Handoff note (optional)',
          ),
        ),
        if (error != null) Text(error!),
      ],
    ),
  );
}

class MemoryEditor extends StatefulWidget {
  const MemoryEditor({super.key, required this.api, this.botId, this.entry});
  final RelayApi api;
  final String? botId;
  final Json? entry;
  @override
  State<MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<MemoryEditor> {
  late final name = TextEditingController(
    text: widget.entry?['key'] as String? ?? '',
  );
  late final content = TextEditingController(
    text: widget.entry?['content'] as String? ?? '',
  );
  String? error;
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    content.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.api.saveMemory(widget.entry?['id'] as String?, {
        'botId': widget.botId,
        'key': name.text,
        'content': content.text,
      });
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => WorkspaceDialog(
    title: widget.entry == null ? 'Add memory' : 'Edit memory',
    actions: [
      FilledButton(
        onPressed: saving ? null : save,
        child: const Text('Save memory'),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        TextField(
          controller: name,
          enabled: widget.entry == null,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        TextField(
          controller: content,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(labelText: 'Memory'),
        ),
        if (error != null) Text(error!),
      ],
    ),
  );
}

/// Asks how to finish a bug recording. Null keeps recording; otherwise the
/// result says whether to save it, with the user's description.
Future<({bool save, String description})?> askBugReport(
  BuildContext context,
  int events,
) {
  final description = TextEditingController();
  return showDialog<({bool save, String description})>(
    context: context,
    builder: (context) => WorkspaceDialog(
      title: 'Save bug report',
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, (save: false, description: '')),
          child: const Text('Discard'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (
            save: true,
            description: description.text.trim(),
          )),
          child: const Text('Save on server'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$events recorded events, a screenshot of the current page and '
            'the server record of this conversation will be saved.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: description,
            autofocus: true,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'What went wrong?',
              hintText: 'What you expected and what happened instead',
            ),
          ),
        ],
      ),
    ),
  );
}
