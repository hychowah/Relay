import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace.dart';
import 'workspace_style.dart';

class ConversationHistory extends StatefulWidget {
  const ConversationHistory({
    super.key,
    required this.workspace,
    required this.onSelected,
  });
  final Workspace workspace;
  final VoidCallback onSelected;
  @override
  State<ConversationHistory> createState() => _ConversationHistoryState();
}

class _ConversationHistoryState extends State<ConversationHistory> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  final search = TextEditingController();
  Timer? debounce;
  List<Conversation> items = [];
  bool trash = false, loading = true, working = false;
  String? error;
  late String scope = widget.workspace.selectedBotId ?? '';
  int request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final current = ++request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.workspace.conversations(
        query: search.text,
        trash: trash,
      );
      if (mounted && current == request) {
        setState(
          () => items = result
              .where((item) => scope == '*' || (item.botId ?? '') == scope)
              .toList(),
        );
      }
    } catch (e) {
      if (mounted && current == request) setState(() => error = e.toString());
    } finally {
      if (mounted && current == request) setState(() => loading = false);
    }
  }

  Future<void> act(
    Future<void> Function() action, {
    bool select = false,
  }) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      await action();
      if (!mounted) return;
      if (select) {
        widget.onSelected();
        Navigator.pop(context);
      } else {
        await load();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> remove(Conversation conversation) async {
    final selected = conversation.id == widget.workspace.conversationId;
    await act(() async {
      await widget.workspace.trashConversation(conversation.id);
      if (selected) widget.onSelected();
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 540,
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          spacing: 12,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    trash ? 'Trash' : 'Conversations',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: trash ? 'Show conversations' : 'Show Trash',
                  onPressed: working
                      ? null
                      : () {
                          setState(() => trash = !trash);
                          unawaited(load());
                        },
                  icon: Icon(
                    trash ? Icons.chat_bubble_outline : Icons.delete_outline,
                  ),
                ),
                IconButton(
                  tooltip: 'Close history',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: scope,
              decoration: const InputDecoration(labelText: 'Conversations for'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Personal chat')),
                const DropdownMenuItem(
                  value: '*',
                  child: Text('All conversations'),
                ),
                ...widget.workspace.bots.map(
                  (b) => DropdownMenuItem(
                    value: b['id'] as String,
                    child: Text(b['name'] as String),
                  ),
                ),
              ],
              onChanged: working
                  ? null
                  : (value) {
                      scope = value!;
                      load();
                    },
            ),
            if (trash)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Conversations can be restored for 24 hours.'),
              )
            else ...[
              TextField(
                controller: search,
                decoration: const InputDecoration(
                  labelText: 'Search conversations',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) {
                  debounce?.cancel();
                  request++;
                  debounce = Timer(const Duration(milliseconds: 250), load);
                },
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: working || widget.workspace.sending
                      ? null
                      : () =>
                            act(widget.workspace.newConversation, select: true),
                  icon: const Icon(Icons.add),
                  label: const Text('New conversation'),
                ),
              ),
            ],
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
            if (loading || working) const LinearProgressIndicator(),
            Expanded(
              child: items.isEmpty && !loading
                  ? Center(
                      child: Text(
                        trash ? 'Trash is empty' : 'No conversations found',
                      ),
                    )
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return ListTile(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          leading: Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 17,
                            color: colors.onSurfaceVariant,
                          ),
                          selected: item.id == widget.workspace.conversationId,
                          title: Text(
                            item.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            ((trash ? item.trashedAt : item.createdAt) ?? '')
                                .split('T')
                                .first,
                          ),
                          onTap: trash || working || widget.workspace.sending
                              ? null
                              : () => act(
                                  () => widget.workspace.selectConversation(
                                    item.id,
                                  ),
                                  select: true,
                                ),
                          trailing: trash
                              ? IconButton(
                                  tooltip: 'Restore conversation',
                                  icon: const Icon(Icons.restore),
                                  onPressed: working
                                      ? null
                                      : () => act(
                                          () => widget.workspace
                                              .restoreConversation(item.id),
                                        ),
                                )
                              : ConfirmDeleteButton(
                                  tooltip: 'Move conversation to Trash',
                                  label: 'Move to Trash',
                                  onConfirmed: working
                                      ? null
                                      : () => remove(item),
                                ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
