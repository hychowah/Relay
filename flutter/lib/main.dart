import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'relay_api.dart';
import 'web_page.dart';
import 'workspace.dart';
import 'conversation_history.dart';
import 'provider_settings.dart';
import 'workspace_dialogs.dart';
import 'app_library.dart';
import 'app_updates.dart';
import 'conversation_view.dart';
import 'workspace_style.dart';
import 'workspace_tabs.dart';
import 'region_capture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final device = prefs.getString('device') ?? const Uuid().v4();
  await prefs.setString('device', device);
  final workspace = Workspace(
    api: RelayApi(
      Uri.parse(
        const String.fromEnvironment(
          'RELAY_URL',
          defaultValue: 'http://127.0.0.1:3250',
        ),
      ),
    ),
    deviceId: device,
    pages: createWebPage,
    conversationId: prefs.getString('conversation'),
    pendingSession: prefs.getString('updateSession') == null
        ? null
        : jsonDecode(prefs.getString('updateSession')!) as Json,
    sessionRestored: () async {
      await prefs.remove('updateSession');
    },
    saveConversation: (id) async {
      if (id == null) {
        await prefs.remove('conversation');
      } else {
        await prefs.setString('conversation', id);
      }
    },
  );
  final connection = BrowserConnection(
    Uri.parse(
      const String.fromEnvironment(
        'BROWSER_URL',
        defaultValue: 'http://127.0.0.1:3251',
      ),
    ),
    workspace.browserSessionId,
    workspace.readBrowser,
    (_) => workspace.changed(),
  );
  unawaited(connection.connect());
  final updates = await AppUpdates.create(
    Uri.parse(
      const String.fromEnvironment(
        'RELAY_UPDATE_URL',
        defaultValue: String.fromEnvironment(
          'RELAY_URL',
          defaultValue: 'http://127.0.0.1:3250',
        ),
      ),
    ),
  );
  runApp(
    RelayApp(
      workspace: workspace,
      updates: updates,
      saveSession: () async {
        if (workspace.pendingSession == null) {
          await prefs.setString(
            'updateSession',
            jsonEncode(workspace.session()),
          );
        }
      },
      initialDraft: prefs.getString('draft') ?? '',
      initialChatWidth: prefs.getDouble('chatWidth') ?? .30,
      saveChatWidth: (width) async {
        await prefs.setDouble('chatWidth', width);
      },
      saveDraft: (text) async {
        await prefs.setString('draft', text);
      },
      onClose: connection.close,
    ),
  );
  unawaited(workspace.start());
}

class RelayApp extends StatelessWidget {
  const RelayApp({
    super.key,
    required this.workspace,
    this.initialDraft = '',
    this.initialChatWidth = .30,
    this.saveChatWidth,
    required this.saveDraft,
    this.onClose,
    this.updates,
    this.saveSession,
  });
  final Workspace workspace;
  final String initialDraft;
  final double initialChatWidth;
  final Future<void> Function(double)? saveChatWidth;
  final Future<void> Function(String) saveDraft;
  final VoidCallback? onClose;
  final AppUpdates? updates;
  final Future<void> Function()? saveSession;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Relay Flutter — experiment',
    debugShowCheckedModeBanner: false,
    theme: workspaceTheme(),
    builder: (context, child) => Theme(
      data: MediaQuery.sizeOf(context).width < 900
          ? Theme.of(context).copyWith(
              visualDensity: VisualDensity.standard,
              iconButtonTheme: IconButtonThemeData(
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  iconSize: 20,
                ),
              ),
            )
          : Theme.of(context),
      child: child!,
    ),
    home: RelayShell(
      workspace: workspace,
      initialDraft: initialDraft,
      initialChatWidth: initialChatWidth,
      saveChatWidth: saveChatWidth,
      saveDraft: saveDraft,
      onClose: onClose,
      updates: updates,
      saveSession: saveSession,
    ),
  );
}

class RelayShell extends StatefulWidget {
  const RelayShell({
    super.key,
    required this.workspace,
    required this.initialDraft,
    this.initialChatWidth = .30,
    this.saveChatWidth,
    required this.saveDraft,
    this.onClose,
    this.updates,
    this.saveSession,
  });
  final Workspace workspace;
  final String initialDraft;
  final double initialChatWidth;
  final Future<void> Function(double)? saveChatWidth;
  final Future<void> Function(String) saveDraft;
  final VoidCallback? onClose;
  final AppUpdates? updates;
  final Future<void> Function()? saveSession;
  @override
  State<RelayShell> createState() => _RelayShellState();
}

class _RelayShellState extends State<RelayShell> {
  Workspace get w => widget.workspace;
  late final TextEditingController draft;
  final address = TextEditingController();
  final messagesScroll = ScrollController();
  Timer? saveTimer;
  ({String appId, Uint8List bytes})? capture;
  bool capturing = false;
  ({WorkspaceTab tab, ui.Image image, bool reopenChat})? selecting;
  bool chatOpen = true, chatOnly = false;
  late double chatWidth = widget.initialChatWidth;
  int lastPresentation = 0;
  String? lastPageUrl;
  @override
  void initState() {
    super.initState();
    draft = TextEditingController(text: widget.initialDraft);
    draft.addListener(_save);
    w.addListener(_changed);
    widget.updates?.addListener(_changed);
  }

  void _save() {
    saveTimer?.cancel();
    saveTimer = Timer(
      const Duration(milliseconds: 300),
      () => widget.saveDraft(draft.text),
    );
  }

  void _changed() {
    if (mounted) {
      if (selecting != null && w.active != selecting!.tab) _finishCapture(null);
      setState(() {
        if (lastPresentation != w.presentations) {
          chatOnly = false;
          if (MediaQuery.sizeOf(context).width < 900) chatOpen = false;
        }
        lastPresentation = w.presentations;
      });
    }
  }

  @override
  void dispose() {
    saveTimer?.cancel();
    unawaited(widget.saveDraft(draft.text));
    draft.dispose();
    address.dispose();
    messagesScroll.dispose();
    selecting?.image.dispose();
    w.removeListener(_changed);
    widget.updates?.removeListener(_changed);
    widget.updates?.dispose();
    w.dispose();
    widget.onClose?.call();
    super.dispose();
  }

  Future<void> _choose(WorkspaceApp app) async {
    setState(() => chatOnly = false);
    try {
      await w.chooseApp(
        app,
        (id) => showDialog<void>(
          context: context,
          builder: (_) => AppLibrary(workspace: w, appId: id),
        ),
      );
      if (mounted && MediaQuery.sizeOf(context).width < 900) {
        setState(() => chatOpen = false);
      }
    } catch (_) {}
  }

  Future<void> _capture() async {
    final tab = w.active;
    final page = tab?.page;
    if (tab?.appId == null || page == null || capturing || selecting != null) {
      return;
    }
    setState(() => capturing = true);
    try {
      final image = await decodeFrame(await page.snapshot());
      if (!mounted || w.active != tab) {
        image.dispose();
        return;
      }
      // A phone's chat sheet covers the page, so step it aside while selecting.
      final phone = MediaQuery.sizeOf(context).width < 900;
      setState(() {
        selecting = (tab: tab!, image: image, reopenChat: phone && chatOpen);
        chatOnly = false;
        if (phone) chatOpen = false;
      });
    } catch (error) {
      w.error = error.toString();
      w.changed();
    } finally {
      if (mounted) setState(() => capturing = false);
    }
  }

  void _finishCapture(Uint8List? bytes) {
    final current = selecting;
    if (current == null) return;
    setState(() {
      selecting = null;
      if (current.reopenChat) chatOpen = true;
      if (bytes != null) capture = (appId: current.tab.appId!, bytes: bytes);
    });
    // Let the overlay leave the tree before its frame is released.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => current.image.dispose(),
    );
  }

  Future<void> _send() async {
    final text = draft.text;
    if (text.trim().isEmpty || w.busy) return;
    final attachment = capture;
    try {
      await w.send(text, capture: attachment);
      if (mounted && capture == attachment) setState(() => capture = null);
      if (mounted && draft.text == text) {
        draft.clear();
        if (messagesScroll.hasClients) messagesScroll.jumpTo(0);
      }
    } catch (_) {}
  }

  void _selectedConversation() {
    draft.clear();
    setState(() {
      chatOpen = true;
      capture = null;
    });
  }

  Future<void> _newConversation() async {
    try {
      await w.newConversation();
      if (mounted) _selectedConversation();
    } catch (e) {
      w.error = e.toString();
      w.changed();
    }
  }

  Future<void> _menu(String action) async {
    try {
      switch (action) {
        case 'provider':
          await showDialog<void>(
            context: context,
            builder: (_) => ProviderSettings(workspace: w),
          );
        case 'bots':
          await showBots(context, w, _selectedConversation);
        case 'memory':
          await showDialog<void>(
            context: context,
            builder: (_) =>
                MemoryDialog(workspace: w, onSelected: _selectedConversation),
          );
        case 'forward':
          await showDialog<void>(
            context: context,
            builder: (_) =>
                ForwardDialog(workspace: w, onSelected: _selectedConversation),
          );
        case 'library':
          await showDialog<void>(
            context: context,
            builder: (_) => AppLibrary(workspace: w),
          );
        case 'updates':
          unawaited(widget.updates!.loadPreviews());
          await showDialog<void>(
            barrierDismissible: false,
            context: context,
            builder: (_) => ListenableBuilder(
              listenable: w,
              builder: (_, _) => UpdateDialog(
                updates: widget.updates!,
                busy: () => w.busy,
                install: () async {
                  if (w.busy) return;
                  await widget.updates!.install(() async {
                    await w.api.checkIdleBeforeRestart(
                      w.deviceId,
                      w.windowId,
                      allowOffline:
                          widget.updates!.returningToStable &&
                          w.api.origin != widget.updates!.origin,
                    );
                    saveTimer?.cancel();
                    await widget.saveDraft(draft.text);
                    await widget.saveSession?.call();
                  });
                },
              ),
            ),
          );
        case 'reconnect':
          await w.start();
        case 'chat':
          setState(() {
            chatOnly = true;
            chatOpen = true;
          });
      }
    } catch (e) {
      w.error = e.toString();
      w.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = w.active?.page?.url;
    if (url != lastPageUrl) {
      lastPageUrl = url;
      address.text = url == 'about:blank' ? '' : url ?? '';
    }
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _toolbar(),
            if (w.error != null)
              MaterialBanner(
                content: Text(w.error!, maxLines: 3),
                actions: [
                  TextButton(
                    onPressed: () {
                      w.error = null;
                      w.changed();
                    },
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, size) {
                  final page = Column(
                    children: [
                      if (w.active?.isBrowser == true)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                tooltip: 'Back',
                                onPressed:
                                    w.active?.page?.browser?.canGoBack == true
                                    ? () => w.browserAction('back')
                                    : null,
                                icon: const Icon(Icons.arrow_back),
                              ),
                              IconButton(
                                tooltip: 'Forward',
                                onPressed:
                                    w.active?.page?.browser?.canGoForward ==
                                        true
                                    ? () => w.browserAction('forward')
                                    : null,
                                icon: const Icon(Icons.arrow_forward),
                              ),
                              IconButton(
                                tooltip: 'Reload',
                                onPressed: () => w.browserAction('reload'),
                                icon: const Icon(Icons.refresh),
                              ),
                              Expanded(
                                child: TextField(
                                  controller: address,
                                  decoration: const InputDecoration(
                                    hintText: 'Search or enter a web address',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                  ),
                                  onSubmitted: w.navigate,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Go',
                                onPressed: () => w.navigate(address.text),
                                icon: const Icon(Icons.arrow_forward),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: Stack(
                          children: [
                            for (final tab in w.tabs)
                              if (tab.page != null)
                                Positioned.fill(
                                  key: ValueKey(tab.id),
                                  child: Offstage(
                                    offstage: w.active != tab,
                                    child: tab.page!.widget,
                                  ),
                                ),
                            if (selecting case final s? when s.tab == w.active)
                              Positioned.fill(
                                child: RegionCapture(
                                  key: ValueKey(s.image),
                                  image: s.image,
                                  onDone: _finishCapture,
                                ),
                              ),
                            if (w.active == null || w.active?.appId == null)
                              Positioned.fill(
                                child: NewTabPage(
                                  key: ValueKey(w.active?.id),
                                  apps: w.allowedApps,
                                  onChoose: _choose,
                                ),
                              ),
                            if (w.active?.report != null &&
                                (w.active?.page == null ||
                                    w.active?.error != null))
                              Positioned.fill(
                                child: SavedReport(
                                  report: w.active!.report!,
                                  error: w.active?.error,
                                ),
                              ),
                            if (w.active?.error != null &&
                                w.active?.report == null)
                              Center(child: Text(w.active!.error!)),
                            if (w.active?.appId != null &&
                                w.active?.page == null &&
                                w.active?.report == null)
                              const Center(child: CircularProgressIndicator()),
                          ],
                        ),
                      ),
                    ],
                  );
                  return _panels(size, page);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panels(BoxConstraints size, Widget page) {
    final desktop = size.maxWidth >= 900;
    final minFraction = (320 / size.maxWidth).clamp(.2, .5);
    final fraction = chatWidth.clamp(minFraction, .5);
    final panelWidth = desktop ? size.maxWidth * fraction : size.maxWidth;
    final target = chatOnly
        ? 2.0
        : chatOpen
        ? 1.0
        : 0.0;
    final divider = MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => setState(() {
          chatWidth = (fraction - details.delta.dx / size.maxWidth).clamp(
            minFraction,
            .5,
          );
        }),
        onHorizontalDragEnd: (_) => widget.saveChatWidth?.call(chatWidth),
        child: const ColoredBox(color: line),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target),
      duration: workspaceMotion(context),
      curve: Curves.easeOutCubic,
      child: ExcludeFocus(excluding: !chatOpen, child: _chat()),
      builder: (context, value, chat) {
        // 0 is closed, 1 is docked (or a sheet), and 2 fills the workspace.
        final reveal = value.clamp(0.0, 1.0);
        final expand = (value - 1).clamp(0.0, 1.0);
        final gutter = desktop ? 6 * (1 - expand) : 0.0;
        final width = panelWidth + (size.maxWidth - panelWidth) * expand;
        final height = size.maxHeight * (desktop ? 1 : .72 + .28 * expand);
        return Stack(
          children: [
            Positioned.fill(
              right: desktop ? (panelWidth + 6) * reveal : 0,
              child: Offstage(
                offstage: expand == 1,
                child: ExcludeFocus(excluding: chatOnly, child: page),
              ),
            ),
            if (!desktop && reveal < 1)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: ExcludeFocus(
                  excluding: chatOpen,
                  child: IgnorePointer(
                    ignoring: chatOpen,
                    child: Opacity(opacity: 1 - reveal, child: _compactChat()),
                  ),
                ),
              ),
            if (value > 0)
              Positioned(
                key: const ValueKey('conversation-panel'),
                right: desktop ? -(width + gutter) * (1 - reveal) : 0,
                bottom: desktop ? 0 : -height * (1 - reveal),
                width: width + gutter,
                height: height,
                child: IgnorePointer(
                  ignoring: !chatOpen,
                  child: Row(
                    children: [
                      if (desktop)
                        SizedBox(width: gutter, height: height, child: divider),
                      Expanded(
                        child: Material(
                          elevation: desktop ? 0 : 12 * (1 - expand),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(
                              desktop ? 0 : 18 * (1 - expand),
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: chat,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _compactChat() => Card(
    child: Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: () => setState(() => chatOpen = true),
            child: Text(
              w.status ??
                  (w.messages.isEmpty ? 'Talk to Relay' : 'Open conversation'),
            ),
          ),
        ),
        if (w.busy) TextButton(onPressed: w.stop, child: const Text('Stop')),
      ],
    ),
  );

  Widget _toolbar() => Container(
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: const BoxDecoration(
      color: canvas,
      border: Border(bottom: BorderSide(color: line)),
    ),
    child: Row(
      children: [
        const RelayMark(size: 24),
        if (MediaQuery.sizeOf(context).width >= 600) ...[
          const SizedBox(width: 9),
          const Text(
            'Relay',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ],
        const SizedBox(width: 18),
        Expanded(
          child: WorkspaceTabs(
            tabs: List.of(w.tabs),
            selected: chatOnly ? null : w.active,
            onSelect: (tab) {
              setState(() => chatOnly = false);
              w.select(tab);
            },
            onClose: w.closeTab,
          ),
        ),
        IconButton(
          tooltip: 'New tab',
          onPressed: () {
            setState(() => chatOnly = false);
            w.newTab();
            if (MediaQuery.sizeOf(context).width < 900) {
              setState(() => chatOpen = false);
            }
          },
          icon: const Icon(Icons.add),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Toggle chat',
          onPressed: () => setState(() {
            chatOpen = !chatOpen;
            chatOnly = false;
          }),
          icon: Icon(
            Icons.view_sidebar_outlined,
            color: chatOpen ? accent : muted,
          ),
        ),
        MenuAnchor(
          animated: !MediaQuery.disableAnimationsOf(context),
          builder: (context, controller, child) => IconButton(
            tooltip: 'Workspace menu',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.tune_rounded),
          ),
          menuChildren: [
            const MenuLabel('WORKSPACE'),
            _menuItem('library', 'App library', Icons.grid_view_rounded),
            _menuItem('bots', 'Bots', Icons.smart_toy_outlined),
            _menuItem('memory', 'Memory', Icons.bookmarks_outlined),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Divider(),
            ),
            const MenuLabel('CONNECTION'),
            _menuItem('provider', 'Provider and model', Icons.tune_rounded),
            _menuItem('reconnect', 'Reconnect', Icons.refresh_rounded),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Divider(),
            ),
            _menuItem('chat', 'Chat only', Icons.chat_bubble_outline_rounded),
            if (widget.updates != null)
              _menuItem(
                'updates',
                widget.updates!.ready ? 'Update ready' : 'Updates',
                Icons.system_update_alt_rounded,
              ),
          ],
        ),
      ],
    ),
  );

  Widget _menuItem(
    String action,
    String label,
    IconData icon, {
    bool enabled = true,
  }) => MenuItemButton(
    leadingIcon: Icon(icon, size: 17),
    onPressed: enabled ? () => _menu(action) : null,
    child: Text(label),
  );

  Widget _chat() => Material(
    color: Colors.white,
    child: Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 10, 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: line)),
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
                      style: const TextStyle(fontSize: 11, color: muted),
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
                          onSelected: _selectedConversation,
                        ),
                      ),
                icon: const Icon(Icons.history_rounded),
              ),
              IconButton(
                tooltip: 'New conversation',
                onPressed: w.sending ? null : _newConversation,
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
                  _menuItem(
                    'forward',
                    'Forward conversation',
                    Icons.forward_to_inbox_outlined,
                    enabled:
                        w.conversationId != null &&
                        !w.busy &&
                        w.bots.isNotEmpty,
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.unfold_more, size: 17),
                    onPressed: () => setState(() {
                      chatOnly = !chatOnly;
                      chatOpen = true;
                    }),
                    child: Text(
                      chatOnly ? 'Show workspace' : 'Expand conversation',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ConversationMessages(
                workspace: w,
                controller: messagesScroll,
                onSelected: _selectedConversation,
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
                  const Icon(
                    Icons.check_circle_outline,
                    size: 14,
                    color: accent,
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    w.status ?? 'Working…',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: _composer(),
          ),
        ),
      ],
    ),
  );

  Widget _composer() => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
    child: Container(
      decoration: BoxDecoration(
        color: canvas,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: line),
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
                      color: w.includeContext ? tint : Colors.transparent,
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
                          color: accent,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            (w.active!.page!.context?['selection'] as String? ??
                                        '')
                                    .isNotEmpty
                                ? '“${w.active!.page!.context!['selection']}”'
                                : w.active!.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: accent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (capture case final attachment?)
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                dense: true,
                leading: Image.memory(
                  attachment.bytes,
                  width: 52,
                  height: 38,
                  fit: BoxFit.contain,
                ),
                subtitle: w.provider['supportsImageInput'] == true
                    ? null
                    : const Text('Choose Claude to send this image.'),
                title: Text(
                  'Screenshot · ${attachment.appId}',
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Remove screenshot',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => capture = null),
                ),
              ),
            ),
          Focus(
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isShiftPressed &&
                  !draft.value.composing.isValid) {
                if (!w.busy) unawaited(_send());
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: TextField(
              controller: draft,
              onTap: () async {
                if (w.includeContext &&
                    w.allowedApps.any((app) => app.id == w.active?.appId)) {
                  await w.active?.page?.refreshSelection();
                  if (mounted) setState(() {});
                }
              },
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
                      onPressed: () => _menu('provider'),
                      style: TextButton.styleFrom(
                        foregroundColor: muted,
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
                    onPressed: capturing || selecting != null || w.busy
                        ? null
                        : _capture,
                  ),
                if (w.provider['supportsReasoningEffort'] == true)
                  MenuAnchor(
                    animated: !MediaQuery.disableAnimationsOf(context),
                    builder: (context, controller, child) => TextButton(
                      onPressed: () => controller.isOpen
                          ? controller.close()
                          : controller.open(),
                      style: TextButton.styleFrom(
                        foregroundColor: muted,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.psychology_outlined, size: 15),
                          const SizedBox(width: 4),
                          Text(
                            effortNames[w
                                    .snapshot
                                    ?.conversation
                                    ?.reasoningEffort] ??
                                'Thinking',
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
                            (w.snapshot?.conversation?.reasoningEffort ??
                                        'inherit') ==
                                    entry.key
                                ? Icons.check
                                : null,
                            size: 16,
                          ),
                          onPressed: w.busy
                              ? null
                              : () async {
                                  try {
                                    await w.changeEffort(
                                      entry.key == 'inherit' ? null : entry.key,
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
                  onPressed: w.busy ? w.stop : _send,
                  style: IconButton.styleFrom(
                    backgroundColor: ink,
                    foregroundColor: Colors.white,
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

class NewTabPage extends StatefulWidget {
  const NewTabPage({super.key, required this.apps, required this.onChoose});
  final List<WorkspaceApp> apps;
  final Future<void> Function(WorkspaceApp) onChoose;
  @override
  State<NewTabPage> createState() => _NewTabPageState();
}

class _NewTabPageState extends State<NewTabPage> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final matches = widget.apps
        .where(
          (app) => '${app.name} ${app.description}'.toLowerCase().contains(
            search.trim().toLowerCase(),
          ),
        )
        .toList();
    return LayoutBuilder(
      builder: (context, size) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          28,
          size.maxHeight > 500 ? 76 : 28,
          28,
          28,
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'YOUR WORKSPACE',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'What would you like to open?',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your apps, connected by one conversation.',
                  style: TextStyle(fontSize: 14, color: muted),
                ),
                const SizedBox(height: 28),
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search apps',
                    prefixIcon: Icon(Icons.search_rounded, size: 19),
                    fillColor: Colors.white,
                  ),
                  onChanged: (value) => setState(() => search = value),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) widget.onChoose(matches.first);
                  },
                ),
                const SizedBox(height: 28),
                const Text(
                  'APPS',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: muted,
                  ),
                ),
                const SizedBox(height: 12),
                for (final app in matches)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: line),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => widget.onChoose(app),
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: tint,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  app.isBrowser
                                      ? Icons.language_rounded
                                      : Icons.grid_view_rounded,
                                  size: 20,
                                  color: accent,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      app.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      app.description ?? '',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: muted,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Icon(Icons.arrow_outward_rounded, size: 17),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                if (matches.isEmpty)
                  const Text(
                    'No matching apps.',
                    style: TextStyle(color: muted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
