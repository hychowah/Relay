import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'area_capture.dart';
import 'browser_transcript.dart';
import 'chat_dock.dart';
import 'conversation_history.dart';
import 'conversation_view.dart';
import 'provider_settings.dart';
import 'transcript_pane.dart';
import 'workspace.dart';
import 'workspace_menu.dart';
import 'workspace_style.dart';

/// What the next message is made of, kept while the panel is closed
/// (closing unmounts it): the draft, saved 300 ms after each change and on
/// dispose; the transcript selection, dropped by [follow] once its pane hides
/// or the page has a newer selection; the messages' scroll. Does nothing once
/// disposed. A new transcript selection and a refreshed page selection notify
/// its listeners, as the shell's `setState` did, so the shell redraws as
/// before; [follow] runs during the shell's build and never notifies.
class ChatInput extends ChangeNotifier {
  ChatInput(
    this.workspace,
    this._layout,
    this._capture,
    String draft,
    this._saveDraft,
  ) : _draft = TextEditingController(text: draft) {
    _draft.addListener(_save);
  }
  final Workspace workspace;
  final ChatLayout _layout;
  final AreaCapture _capture;
  final Future<void> Function(String) _saveDraft;
  final TextEditingController _draft;
  final _messagesScroll = ScrollController();
  Timer? _saveTimer;
  ({String pane, String text, String page})? _transcriptSelection;
  String? _transcriptPane;
  String _onPage = '';
  bool _disposed = false;
  Workspace get w => workspace;

  /// The message being written.
  TextEditingController get draft => _draft;

  /// The conversation's messages; a sent message scrolls them to the newest.
  ScrollController get messages => _messagesScroll;

  /// Desktop only. The open transcript pane's key, for its tab and video;
  /// null while no transcript pane shows.
  String? get transcriptPane => _transcriptPane;

  /// Desktop only. The text the user selected in the transcript, sent as the
  /// next message's selection; setting it ties it to the pane and the page's
  /// selection [follow] last saw.
  String? get transcriptSelection => _transcriptSelection?.text;
  set transcriptSelection(String? text) {
    _transcriptSelection = text == null
        ? null
        : (pane: _transcriptPane!, text: text, page: _onPage);
    notifyListeners();
  }

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 300),
      () => _saveDraft(_draft.text),
    );
  }

  /// Saves the draft at once, as before an update restarts the app.
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _saveDraft(_draft.text);
  }

  /// Follows the selected [tab] on every shell build, before the panel reads
  /// the transcript selection: works out the transcript pane, shown on a
  /// [desktop] for a YouTube video in a Browser tab, and drops a transcript
  /// selection that applies no longer, even while chat is closed.
  void follow(WorkspaceTab? tab, {required bool desktop}) {
    final browser = tab?.page?.browser;
    final video = desktop && browser != null
        ? youtubeVideoId(tab!.page!.url)
        : null;
    _transcriptPane = video != null && _layout.transcriptOpen
        ? '${tab!.id} $video'
        : null;
    final onPage = tab?.page?.context?['selection'] as String? ?? '';
    // A transcript selection applies only while its pane is showing and until
    // the user selects something newer on the page.
    if (_transcriptSelection case final kept?
        when kept.pane != _transcriptPane ||
            (onPage.isNotEmpty && onPage != kept.page)) {
      _transcriptSelection = null;
    }
    _onPage = onPage;
  }

  /// Sends the draft with the attachment and the transcript selection, unless
  /// the draft is empty or a reply runs. The draft clears unless the user
  /// changed it meanwhile; a failure keeps it.
  Future<void> send() async {
    final text = _draft.text;
    if (text.trim().isEmpty || w.busy) return;
    final attachment = _capture.attachment;
    try {
      await w.send(
        text,
        capture: attachment,
        selection: _transcriptSelection?.text,
      );
      if (!_disposed) _capture.sent(attachment);
      if (!_disposed && _draft.text == text) {
        _draft.clear();
        if (_messagesScroll.hasClients) _messagesScroll.jumpTo(0);
      }
    } catch (_) {}
  }

  /// A conversation was chosen: the draft clears; the caller redraws.
  void clear() => _draft.clear();

  /// The field was tapped: an included page that the selected bot may read
  /// reads its selection again, and the shell redraws to label it.
  Future<void> refreshSelection() async {
    if (w.includeContext &&
        w.allowedApps.any((app) => app.id == w.active?.appId)) {
      await w.active?.page?.refreshSelection();
      if (!_disposed) notifyListeners();
    }
  }

  /// Saves the draft once more and releases the field and the scroll.
  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    unawaited(_saveDraft(_draft.text));
    _draft.dispose();
    _messagesScroll.dispose();
    super.dispose();
  }
}

/// The chat panel: the conversation's header, the transcript card, the
/// messages, the status and the composer. It keeps nothing itself; what
/// outlives it, as it unmounts while chat is closed, is in [input].
class ChatPanel extends StatelessWidget {
  const ChatPanel(
    this.workspace,
    this.desktop,
    this.input,
    this.layout,
    this.capture,
    this.actions,
    this.onConversationChosen,
    this.onNewConversation, {
    super.key,
  });
  final Workspace workspace;
  final bool desktop;
  final ChatInput input;
  final ChatLayout layout;
  final AreaCapture capture;
  final ShellActions actions;
  final VoidCallback onConversationChosen;
  final VoidCallback onNewConversation;
  Workspace get w => workspace;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.outline)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        w.snapshot?.conversation?.title ?? 'Conversation',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        w.activeBot?['name'] as String? ?? 'Personal workspace',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Conversation history',
                  onPressed: w.sending
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => ConversationHistory(
                            workspace: w,
                            onSelected: onConversationChosen,
                          ),
                        ),
                  icon: const Icon(Icons.history_rounded),
                ),
                IconButton(
                  tooltip: 'New conversation',
                  onPressed: w.sending ? null : onNewConversation,
                  icon: const Icon(Icons.edit_square, size: 17),
                ),
                MenuAnchor(
                  animated: !MediaQuery.disableAnimationsOf(context),
                  builder: (context, controller, child) => IconButton(
                    tooltip: 'Conversation options',
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                    icon: const Icon(Icons.more_horiz),
                  ),
                  menuChildren: [
                    actionItem(
                      actions,
                      WorkspaceAction.forward,
                      'Forward conversation',
                      Icons.forward_to_inbox_outlined,
                      enabled:
                          w.conversationId != null &&
                          !w.busy &&
                          w.bots.isNotEmpty,
                    ),
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.unfold_more, size: 17),
                      onPressed: layout.toggleOnly,
                      child: Text(
                        layout.only ? 'Show workspace' : 'Expand conversation',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ..._transcript(context),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 800),
                      child: ConversationMessages(
                        workspace: w,
                        controller: input.messages,
                        onSelected: onConversationChosen,
                      ),
                    ),
                  ),
                ),
                if (w.busy || w.status != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                    child: Row(
                      children: [
                        if (w.busy)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5),
                          )
                        else
                          Icon(
                            Icons.check_circle_outline,
                            size: 14,
                            color: colors.primary,
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            w.status ?? 'Working…',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: _composer(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Desktop only. The transcript of a YouTube video in the active Browser
  /// tab opens above the conversation, which keeps the lower half.
  List<Widget> _transcript(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tab = w.active;
    final browser = tab?.page?.browser;
    final video = desktop && browser != null
        ? youtubeVideoId(tab!.page!.url)
        : null;
    final pane = input.transcriptPane;
    if (video == null) return const [];
    // The bar and pane form one inset card with a gap below and an accent
    // border, so the transcript reads as apart from the conversation's text;
    // the theme's line colour was too faint to show the edge.
    final card = Container(
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.primary.withValues(alpha: .6)),
      ),
      child: Column(
        children: [
          TranscriptBar(
            open: layout.transcriptOpen,
            onToggle: layout.toggleTranscript,
          ),
          if (pane != null)
            Expanded(
              child: TranscriptPane(
                key: ValueKey(pane),
                browser: browser!,
                onSelected: (text) => input.transcriptSelection = text,
              ),
            ),
        ],
      ),
    );
    return [pane == null ? card : Expanded(child: card)];
  }

  Widget _composer(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (w.active?.page?.context != null &&
                w.allowedApps.any((app) => app.id == w.active?.appId))
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Tooltip(
                  message: w.includeContext
                      ? 'Current page included. Click to exclude.'
                      : 'Current page excluded. Click to include.',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      w.includeContext = !w.includeContext;
                      w.changed();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: w.includeContext
                            ? colors.primaryContainer
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            w.includeContext
                                ? Icons.check_circle_outline
                                : Icons.add_circle_outline,
                            size: 14,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              switch (input.transcriptSelection ??
                                  w.active!.page!.context?['selection']) {
                                final String selection
                                    when selection.isNotEmpty =>
                                  '“$selection”',
                                _ => w.active!.title,
                              },
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (capture.attachment case final attachment?)
              Material(
                type: MaterialType.transparency,
                child: ListTile(
                  dense: true,
                  leading: SizedBox(
                    key: capture.slot,
                    width: 52,
                    height: 38,
                    // Hidden while the captured picture is still flying here.
                    child: Opacity(
                      opacity: capture.flying ? 0 : 1,
                      child: Image.memory(
                        attachment.bytes,
                        fit: BoxFit.contain,
                        // A thumbnail-sized decode keeps the landing smooth.
                        cacheWidth:
                            (52 * MediaQuery.devicePixelRatioOf(context))
                                .round(),
                      ),
                    ),
                  ),
                  subtitle: w.provider['supportsImageInput'] == true
                      ? null
                      : const Text(
                          'Choose Claude or OpenAI to send this image.',
                        ),
                  title: Text(
                    'Screenshot · ${attachment.appId}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove screenshot',
                    icon: const Icon(Icons.close),
                    onPressed: capture.remove,
                  ),
                ),
              ),
            Focus(
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed &&
                    !input.draft.value.composing.isValid) {
                  if (!w.busy) unawaited(input.send());
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: input.draft,
                onTap: input.refreshSelection,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Ask Relay about your workspace…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.fromLTRB(14, 12, 14, 8),
                ),
                textInputAction: TextInputAction.newline,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => actions.run(WorkspaceAction.provider),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurfaceVariant,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: Text(
                          w.provider['model'] as String? ?? 'Choose model',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                  if (w.active?.page?.canCapture == true &&
                      w.allowedApps.any((app) => app.id == w.active?.appId))
                    IconButton(
                      tooltip: 'Capture an area',
                      icon: const Icon(Icons.crop_free, size: 18),
                      onPressed: capture.busy || w.busy ? null : capture.start,
                    ),
                  if (w.provider['supportsReasoningEffort'] == true)
                    MenuAnchor(
                      animated: !MediaQuery.disableAnimationsOf(context),
                      builder: (context, controller, child) => TextButton(
                        onPressed: () => controller.isOpen
                            ? controller.close()
                            : controller.open(),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.onSurfaceVariant,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.psychology_outlined, size: 15),
                            const SizedBox(width: 4),
                            Text(
                              effortNames[w.effort] ?? 'Thinking',
                              style: const TextStyle(fontSize: 11),
                            ),
                            const Icon(Icons.expand_more, size: 14),
                          ],
                        ),
                      ),
                      menuChildren: [
                        const MenuLabel('THINKING EFFORT'),
                        for (final entry in {
                          'inherit': 'Connection default',
                          ...effortNames,
                        }.entries)
                          MenuItemButton(
                            leadingIcon: Icon(
                              (w.effort ?? 'inherit') == entry.key
                                  ? Icons.check
                                  : null,
                              size: 16,
                            ),
                            onPressed: w.busy
                                ? null
                                : () async {
                                    try {
                                      await w.changeEffort(
                                        entry.key == 'inherit'
                                            ? null
                                            : entry.key,
                                      );
                                    } catch (e) {
                                      w.error = e.toString();
                                      w.changed();
                                    }
                                  },
                            child: Text(entry.value),
                          ),
                      ],
                    ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: w.busy ? 'Stop response' : 'Send message',
                    onPressed: w.busy ? w.stop : input.send,
                    style: IconButton.styleFrom(
                      backgroundColor: colors.onSurface,
                      foregroundColor: colors.surface,
                    ),
                    icon: Icon(
                      w.busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                      size: 19,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
