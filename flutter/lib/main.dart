import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'address_bar.dart';
import 'area_capture.dart';
import 'chat_dock.dart';
import 'new_tab_page.dart';
import 'browser_connection.dart';
import 'browser_transcript.dart';
import 'relay_api.dart';
import 'web_page.dart';
import 'windows_web_view.dart';
import 'workspace.dart';
import 'conversation_history.dart';
import 'provider_settings.dart';
import 'workspace_menu.dart';
import 'app_library.dart';
import 'app_updates.dart';
import 'conversation_view.dart';
import 'workspace_style.dart';
import 'workspace_tabs.dart';
import 'page_surface.dart';
import 'region_capture.dart';
import 'split_layout.dart';
import 'tab_memory.dart';
import 'tab_preview.dart';
import 'window_capture.dart';
import 'transcript_pane.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    final support = await getApplicationSupportDirectory();
    await registerWindowsWebView('${support.path}\\WebView2');
  }
  final prefs = await SharedPreferences.getInstance();
  final device = prefs.getString('device') ?? const Uuid().v4();
  await prefs.setString('device', device);
  // Open tabs. The key keeps its first name, from when only an update restart
  // saved them, so tabs survive updating from or returning to an older build.
  final session = prefs.getString('updateSession');
  // One upload at a time, so the server keeps the latest tabs; a failure only
  // leaves its copy older.
  var tabsUpload = Future<void>.value();
  final api = RelayApi(
    Uri.parse(
      const String.fromEnvironment(
        'RELAY_URL',
        defaultValue: 'http://127.0.0.1:3250',
      ),
    ),
  );
  // Desktop only: Browser history and highlights.
  final browserHistory = Platform.isMacOS || Platform.isWindows;
  // Shown to the user's other devices beside the tabs this one saves.
  final deviceName = Platform.isMacOS
      ? 'Mac'
      : Platform.isWindows
      ? 'Windows PC'
      : Platform.operatingSystem;
  final workspace = Workspace(
    api: api,
    deviceId: device,
    pages: (spec, changed) =>
        createWebPage(spec, changed, records: browserHistory ? api : null),
    conversationId: prefs.getString('conversation'),
    pendingSession: session == null ? null : jsonDecode(session) as Json,
    storeSession: (session) async {
      await prefs.setString('updateSession', jsonEncode(session));
      tabsUpload = tabsUpload
          .then((_) => api.saveDeviceTabs(device, deviceName, session))
          .catchError((_) {});
    },
    saveConversation: (id) async {
      if (id == null) {
        await prefs.remove('conversation');
      } else {
        await prefs.setString('conversation', id);
      }
    },
    newestTabFirst: prefs.getBool('newestTabFirst') ?? false,
    saveNewestTabFirst: (value) async {
      await prefs.setBool('newestTabFirst', value);
    },
    // Desktop only.
    unloadAfter: Platform.isMacOS || Platform.isWindows
        ? const Duration(minutes: 30)
        : null,
  );
  final connection = BrowserConnection(
    api.origin,
    workspace.browserSessionId,
    workspace.browserTab,
    workspace.shownBrowserTab,
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
      initialDraft: prefs.getString('draft') ?? '',
      initialChatWidth: prefs.getDouble('chatWidth') ?? .30,
      saveChatWidth: (width) async {
        await prefs.setDouble('chatWidth', width);
      },
      initialChatOpen: prefs.getBool('chatOpen') ?? true,
      saveChatOpen: (open) async {
        await prefs.setBool('chatOpen', open);
      },
      saveDraft: (text) async {
        await prefs.setString('draft', text);
      },
      initialThemeMode:
          ThemeMode.values.asNameMap()[prefs.getString('themeMode')] ??
          ThemeMode.system,
      saveThemeMode: (mode) async {
        await prefs.setString('themeMode', mode.name);
      },
      onClose: connection.close,
      browserHistory: browserHistory,
    ),
  );
  unawaited(workspace.start());
}

class RelayApp extends StatefulWidget {
  const RelayApp({
    super.key,
    required this.workspace,
    this.initialDraft = '',
    this.initialChatWidth = .30,
    this.saveChatWidth,
    this.initialChatOpen = true,
    this.saveChatOpen,
    required this.saveDraft,
    this.initialThemeMode = ThemeMode.system,
    this.saveThemeMode,
    this.onClose,
    this.updates,
    this.browserHistory = false,
  });
  final Workspace workspace;
  final String initialDraft;
  final double initialChatWidth;
  final Future<void> Function(double)? saveChatWidth;
  final bool initialChatOpen;
  final Future<void> Function(bool)? saveChatOpen;
  final Future<void> Function(String) saveDraft;
  final ThemeMode initialThemeMode;
  final Future<void> Function(ThemeMode)? saveThemeMode;
  final VoidCallback? onClose;
  final AppUpdates? updates;

  /// Desktop only: Browser tabs keep the server's browsing history, and the
  /// address bar suggests pages from it.
  final bool browserHistory;
  @override
  State<RelayApp> createState() => _RelayAppState();
}

class _RelayAppState extends State<RelayApp> {
  late ThemeMode themeMode = widget.initialThemeMode;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Relay Flutter — experiment',
    debugShowCheckedModeBanner: false,
    theme: workspaceTheme(Brightness.light),
    darkTheme: workspaceTheme(Brightness.dark),
    themeMode: themeMode,
    builder: (context, child) => WindowCapture(
      child: Theme(
        data: MediaQuery.sizeOf(context).width < wideWorkspace
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
    ),
    home: RelayShell(
      workspace: widget.workspace,
      initialDraft: widget.initialDraft,
      initialChatWidth: widget.initialChatWidth,
      saveChatWidth: widget.saveChatWidth,
      initialChatOpen: widget.initialChatOpen,
      saveChatOpen: widget.saveChatOpen,
      saveDraft: widget.saveDraft,
      themeMode: themeMode,
      onThemeMode: (mode) {
        setState(() => themeMode = mode);
        widget.saveThemeMode?.call(mode);
      },
      onClose: widget.onClose,
      updates: widget.updates,
      browserHistory: widget.browserHistory,
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
    this.initialChatOpen = true,
    this.saveChatOpen,
    required this.saveDraft,
    required this.themeMode,
    required this.onThemeMode,
    this.onClose,
    this.updates,
    this.browserHistory = false,
  });
  final Workspace workspace;
  final String initialDraft;
  final double initialChatWidth;
  final Future<void> Function(double)? saveChatWidth;
  final bool initialChatOpen;
  final Future<void> Function(bool)? saveChatOpen;
  final Future<void> Function(String) saveDraft;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeMode;
  final VoidCallback? onClose;
  final AppUpdates? updates;
  final bool browserHistory;
  @override
  State<RelayShell> createState() => _RelayShellState();
}

class _RelayShellState extends State<RelayShell> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  Workspace get w => widget.workspace;
  late final TextEditingController draft;
  late final address = AddressInput(w, history: widget.browserHistory);
  final messagesScroll = ScrollController();
  Timer? saveTimer;
  late final layout = ChatLayout(
    widget.initialChatOpen,
    widget.initialChatWidth,
    widget.saveChatOpen,
    widget.saveChatWidth,
  );
  late final capture = AreaCapture(context, w, layout);
  late final actions = ShellActions(
    context,
    w,
    widget.updates,
    layout,
    _saveDraftNow,
    _selectedConversation,
  );

  /// The pane a tab is being dragged over and the side it would take.
  (WorkspaceTab, SplitSide)? dropping;
  ({String pane, String text, String page})? transcriptSelection;
  int lastPresentation = 0;

  /// The page shown on the whole screen.
  BrowserSurface? onScreen;
  // The conversation last opened on another device opens here too.
  late final AppLifecycleListener _lifecycle;
  // Desktop only (macOS).
  late final tabMemory = TabMemory(readMemory, _loadedPages);
  List<PageSurface> _loadedPages() => [for (final tab in w.tabs) ?tab.page];

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(w.openCurrentConversation());
        unawaited(widget.updates?.check());
      },
    );
    draft = TextEditingController(text: widget.initialDraft);
    draft.addListener(_save);
    layout.addListener(_redraw);
    capture.addListener(_redraw);
    w.addListener(_changed);
    w.recorder.addListener(_changed);
    widget.updates?.addListener(_changed);
  }

  void _save() {
    saveTimer?.cancel();
    saveTimer = Timer(
      const Duration(milliseconds: 300),
      () => widget.saveDraft(draft.text),
    );
  }

  Future<void> _saveDraftNow() async {
    saveTimer?.cancel();
    await widget.saveDraft(draft.text);
  }

  void _changed() {
    if (mounted) {
      capture.follow(w.active);
      setState(() {
        if (lastPresentation != w.presentations) {
          layout.showPage(
            closeChat: MediaQuery.sizeOf(context).width < wideWorkspace,
          );
        }
        lastPresentation = w.presentations;
      });
    }
  }

  void _redraw() => setState(() {});

  @override
  void dispose() {
    _lifecycle.dispose();
    tabMemory.dispose();
    saveTimer?.cancel();
    unawaited(widget.saveDraft(draft.text));
    draft.dispose();
    address.dispose();
    layout.dispose();
    messagesScroll.dispose();
    capture.dispose();
    w.removeListener(_changed);
    w.recorder.removeListener(_changed);
    widget.updates?.removeListener(_changed);
    widget.updates?.dispose();
    w.dispose();
    widget.onClose?.call();
    super.dispose();
  }

  Future<void> _choose(WorkspaceApp app) async {
    layout.showPage();
    try {
      await w.chooseApp(
        app,
        (id) => showDialog<void>(
          context: context,
          builder: (_) => AppLibrary(workspace: w, appId: id),
        ),
      );
      if (mounted && MediaQuery.sizeOf(context).width < wideWorkspace) {
        layout.closeChat();
      }
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = draft.text;
    if (text.trim().isEmpty || w.busy) return;
    final attachment = capture.attachment;
    try {
      await w.send(
        text,
        capture: attachment,
        selection: transcriptSelection?.text,
      );
      if (mounted) capture.sent(attachment);
      if (mounted && draft.text == text) {
        draft.clear();
        if (messagesScroll.hasClients) messagesScroll.jumpTo(0);
      }
    } catch (_) {}
  }

  void _selectedConversation() {
    draft.clear();
    setState(() {
      layout.openChat();
      capture.remove();
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

  @override
  Widget build(BuildContext context) {
    address.follow(w.active);
    // Several controls open or close chat; the panel reopens as it was left.
    layout.saveOpenIfChanged();
    // A fullscreen page takes the whole screen when its tab shows alone; in
    // split view it fills only its own pane. Leaving the screen for any other
    // reason, such as another tab opening, also ends the page's fullscreen.
    w.splitShown = MediaQuery.sizeOf(context).width >= wideWorkspace;
    final inSplit = w.splitShown && w.shownSplit != null;
    final active = w.active?.page?.browser;
    final full = active?.fullScreen == true && !inSplit ? active : null;
    if (full != onScreen) {
      unawaited(onScreen?.fillScreen(false));
      unawaited(full?.fillScreen(true));
      onScreen = full;
    }
    final screen = full != null;
    w.pageShown = !layout.only || screen;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (!screen) _toolbar(),
            if ((w.error ?? w.pollError) != null && !screen)
              MaterialBanner(
                content: Text(w.error ?? w.pollError!, maxLines: 3),
                actions: [
                  TextButton(
                    onPressed: () {
                      w.error = null;
                      w.pollError = null;
                      w.changed();
                    },
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, size) {
                  final desktop = size.maxWidth >= wideWorkspace;
                  final page = LayoutBuilder(
                    builder: (context, area) => _pages(area.biggest, desktop),
                  );
                  return ChatDock(
                    layout,
                    w,
                    size,
                    screen,
                    page,
                    _chat(desktop),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Every tab's page stays in one keyed slot of this stack, so showing it
  /// alone, in a split pane or hidden only changes its position and never
  /// recreates its native view.
  Widget _pages(Size size, bool desktop) {
    final split = desktop ? w.shownSplit?.layout : null;
    final area = Offset.zero & size;
    final rects = <WorkspaceTab, Rect>{};
    final dividers = <(SplitBranch, Rect, Rect)>[];
    if (split != null) {
      split.layOut(
        area,
        pane: (tab, rect) => rects[tab] = rect,
        divider: (branch, area, line) => dividers.add((branch, area, line)),
      );
    } else if (w.active case final tab?) {
      rects[tab] = area;
    }
    final shown = rects.keys.toList();
    Widget pane(WorkspaceTab tab, Widget child, {Key? key}) =>
        Positioned.fromRect(key: key, rect: rects[tab] ?? area, child: child);

    final frame = split == null ? 0.0 : 2.0;
    // A Browser tab's bar sits at the top of its own pane, so selecting
    // another pane never moves a page. A page in fullscreen fills its pane.
    double bar(WorkspaceTab tab) =>
        tab.isBrowser && tab.page?.browser?.fullScreen != true
        ? BrowserBar.height
        : 0;
    // What shows in place of the page, such as its error, starts below it.
    Widget below(WorkspaceTab tab, Widget child, {Key? key}) {
      final rect = rects[tab] ?? area;
      final top = bar(tab) == 0 ? 0.0 : frame + bar(tab);
      return Positioned.fromRect(
        key: key,
        rect: Rect.fromLTRB(rect.left, rect.top + top, rect.right, rect.bottom),
        child: child,
      );
    }

    // A tab dropped on a pane takes the side whose edge is nearest.
    Widget dropZone(WorkspaceTab target) => pane(
      target,
      Builder(
        builder: (zone) {
          SplitSide side(Offset global) {
            final box = zone.findRenderObject()! as RenderBox;
            return SplitSide.nearest(box.globalToLocal(global), box.size);
          }

          return DragTarget<WorkspaceTab>(
            onWillAcceptWithDetails: (details) =>
                details.data != target && details.data is! SplitTab,
            onMove: (details) {
              final next = (target, side(details.offset));
              if (dropping != next) setState(() => dropping = next);
            },
            onLeave: (_) {
              if (dropping?.$1 == target) setState(() => dropping = null);
            },
            onAcceptWithDetails: (details) {
              setState(() {
                dropping = null;
                layout.showPage();
              });
              w.dropInSplit(details.data, target, side(details.offset));
            },
            builder: (context, candidates, _) {
              final hover = dropping;
              if (candidates.isEmpty || hover == null || hover.$1 != target) {
                return const SizedBox.expand();
              }
              final at = hover.$2;
              return Align(
                alignment: switch (at) {
                  SplitSide.left => Alignment.centerLeft,
                  SplitSide.right => Alignment.centerRight,
                  SplitSide.top => Alignment.topCenter,
                  SplitSide.bottom => Alignment.bottomCenter,
                },
                child: FractionallySizedBox(
                  widthFactor: at.axis == Axis.horizontal ? .5 : 1,
                  heightFactor: at.axis == Axis.vertical ? .5 : 1,
                  child: DecoratedBox(
                    key: ValueKey('drop-${at.name}'),
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .12),
                      border: Border.all(color: colors.primary, width: 2),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );

    return Stack(
      children: [
        for (final tab in w.tabs)
          if (tab.page != null)
            pane(
              tab,
              key: ValueKey(tab.id),
              // The selected pane's outline is a frame around its bar and
              // page, never a drawing over the page: anything painted over a
              // native page takes its mouse on macOS. Both panes keep the
              // frame, so selecting only changes a colour and never resizes
              // a page.
              Builder(
                builder: (context) {
                  final edge = ColoredBox(
                    color: split != null && w.active == tab
                        ? colors.primary.withValues(alpha: .45)
                        : Colors.transparent,
                  );
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 0,
                        height: frame,
                        child: edge,
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: frame,
                        child: edge,
                      ),
                      Positioned(
                        left: 0,
                        top: frame,
                        bottom: frame,
                        width: frame,
                        child: edge,
                      ),
                      Positioned(
                        right: 0,
                        top: frame,
                        bottom: frame,
                        width: frame,
                        child: edge,
                      ),
                      Positioned.fill(
                        left: frame,
                        top: frame + bar(tab),
                        right: frame,
                        bottom: frame,
                        child: Offstage(
                          offstage: !rects.containsKey(tab),
                          child: PageSlot(page: tab.page!),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        if (w.active == null)
          Positioned.fill(
            child: NewTabPage(
              apps: w.allowedApps,
              onChoose: _choose,
              onShow: w.refreshApps,
              devices: w.otherDevices,
              onOpenDevice: w.openDeviceTabs,
            ),
          ),
        for (final tab in shown) ...[
          if (capture.pickingOn(tab) case final image?)
            below(
              tab,
              RegionCapture(
                key: ValueKey(image),
                image: image,
                onDone: capture.finish,
              ),
            ),
          if (tab.appId == null)
            pane(
              tab,
              key: ValueKey('new-${tab.id}'),
              NewTabPage(
                apps: w.allowedApps,
                onChoose: _choose,
                onShow: w.refreshApps,
                devices: w.otherDevices,
                onOpenDevice: w.openDeviceTabs,
              ),
            ),
          if (tab.report != null && (tab.page == null || tab.error != null))
            below(
              tab,
              key: ValueKey('report-${tab.id}'),
              SavedReport(
                report: tab.report!,
                error: tab.error,
                onServers: tab.isBrowser
                    ? null
                    : () => actions.run(WorkspaceAction.servers),
              ),
            ),
          if (tab.error != null && tab.report == null)
            below(
              tab,
              key: ValueKey('error-${tab.id}'),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    Text(tab.error!),
                    // The app's server may be stopped.
                    if (!tab.isBrowser)
                      OutlinedButton.icon(
                        onPressed: () => actions.run(WorkspaceAction.servers),
                        icon: const Icon(Icons.dns_outlined),
                        label: const Text('App servers'),
                      ),
                  ],
                ),
              ),
            ),
          if (tab.appId != null &&
              tab.page == null &&
              tab.report == null &&
              tab.error == null)
            below(
              tab,
              key: ValueKey('loading-${tab.id}'),
              const Center(child: CircularProgressIndicator()),
            ),
          // The selected tab's bar keeps one key as the selection moves
          // between panes, so its address field, with the shared controller
          // and focus, is never built twice.
          if (bar(tab) > 0)
            Positioned.fromRect(
              key: ValueKey(w.active == tab ? 'address-bar' : 'bar-${tab.id}'),
              rect: Rect.fromLTWH(
                rects[tab]!.left + frame,
                rects[tab]!.top + frame,
                rects[tab]!.width - 2 * frame,
                bar(tab),
              ),
              // Only the mouse is stopped by the tint, so the keyboard is
              // kept out too: these buttons act on the selected tab.
              child: ExcludeFocus(
                excluding: w.active != tab,
                child: BrowserBar(w, tab, address),
              ),
            ),
          // The other pane's tint is painted over its page on purpose: on
          // macOS a native page loses the mouse wherever Flutter paints over
          // it, so one click there selects the pane.
          if (split != null && w.active != tab)
            pane(
              tab,
              key: ValueKey('pane-${tab.id}'),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) {
                  w.recorder.action('select tab', {'tab': tab.title});
                  w.select(tab);
                },
                child: ColoredBox(
                  color: colors.onSurface.withValues(alpha: .04),
                ),
              ),
            ),
        ],
        for (final (index, (branch, area, line)) in dividers.indexed)
          Positioned.fromRect(
            key: ValueKey('split-divider-$index'),
            rect: line,
            child: _divider(branch, area),
          ),
        if (desktop) ...[for (final tab in shown) dropZone(tab)],
      ],
    );
  }

  Widget _divider(SplitBranch branch, Rect area) {
    final horizontal = branch.axis == Axis.horizontal;
    void drag(DragUpdateDetails details) => setState(
      () => horizontal
          ? branch.resize(details.delta.dx, area.width)
          : branch.resize(details.delta.dy, area.height),
    );
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal ? drag : null,
        onHorizontalDragEnd: horizontal ? (_) => w.changed() : null,
        onVerticalDragUpdate: horizontal ? null : drag,
        onVerticalDragEnd: horizontal ? null : (_) => w.changed(),
        onDoubleTap: () {
          branch.fraction = .5;
          w.changed();
        },
        child: ColoredBox(color: colors.outline),
      ),
    );
  }

  Widget _toolbar() => Container(
    height: 48,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: colors.surfaceContainerHighest,
      border: Border(bottom: BorderSide(color: colors.outline)),
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
          child: DragTarget<WorkspaceTab>(
            onWillAcceptWithDetails: (details) =>
                w.shownSplit?.layout.contains(details.data) ?? false,
            onAcceptWithDetails: (details) => w.leaveSplit(details.data),
            builder: (context, _, _) {
              // Narrow windows show only the selected tab, never the split.
              final split = MediaQuery.sizeOf(context).width >= wideWorkspace
                  ? w.shownSplit
                  : null;
              return ValueListenableBuilder(
                valueListenable: tabMemory,
                builder: (context, memory, _) => WorkspaceTabs(
                  tabs: List.of(w.tabs),
                  selected: layout.only ? null : split ?? w.active,
                  split: split?.layout.tabs,
                  draggable: MediaQuery.sizeOf(context).width >= wideWorkspace,
                  memory: memory,
                  showVpn: Platform.isMacOS,
                  hoverCard: Platform.isMacOS
                      ? (tab, shown) => TabPreview(
                          tab: tab,
                          shown: shown,
                          read: () => readMemory(_loadedPages()),
                        )
                      : null,
                  onSelect: (tab) {
                    w.recorder.action('select tab', {'tab': tab.title});
                    layout.showPage();
                    w.select(tab, alone: true, opened: true);
                  },
                  onClose: w.closeTab,
                ),
              );
            },
          ),
        ),
        IconButton(
          tooltip: 'New tab',
          onPressed: () {
            layout.showPage();
            w.newTab();
            if (MediaQuery.sizeOf(context).width < wideWorkspace) {
              layout.closeChat();
            }
          },
          icon: const Icon(Icons.add),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: w.recorder.recording
              ? 'Recording. Stop and save'
              : 'Record a bug or request',
          onPressed: () => actions.run(WorkspaceAction.record),
          icon: w.recorder.recording
              ? const Icon(Icons.fiber_manual_record, color: Colors.red)
              : Icon(
                  Icons.fiber_manual_record_outlined,
                  color: colors.onSurfaceVariant,
                ),
        ),
        IconButton(
          tooltip: 'Toggle chat',
          onPressed: () {
            w.recorder.action(layout.open ? 'close chat' : 'open chat');
            layout.toggle();
          },
          icon: Icon(
            Icons.view_sidebar_outlined,
            color: layout.open ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
        WorkspaceMenu(
          actions,
          w,
          widget.updates,
          widget.themeMode,
          widget.onThemeMode,
          tabMemory,
        ),
      ],
    ),
  );

  Widget _chat(bool desktop) => Material(
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
        ..._transcript(desktop),
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
                  child: _composer(),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  // Desktop only: the transcript of a YouTube video in the active Browser tab
  // opens above the conversation, which keeps the lower half.
  List<Widget> _transcript(bool desktop) {
    final tab = w.active;
    final browser = tab?.page?.browser;
    final video = desktop && browser != null
        ? youtubeVideoId(tab!.page!.url)
        : null;
    final pane = video != null && layout.transcriptOpen
        ? '${tab!.id} $video'
        : null;
    final onPage = tab?.page?.context?['selection'] as String? ?? '';
    // A transcript selection applies only while its pane is showing and until
    // the user selects something newer on the page; this runs before the
    // composer below reads it.
    if (transcriptSelection case final kept?
        when kept.pane != pane || (onPage.isNotEmpty && onPage != kept.page)) {
      transcriptSelection = null;
    }
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
                onSelected: (text) => setState(
                  () => transcriptSelection = text == null
                      ? null
                      : (pane: pane, text: text, page: onPage),
                ),
              ),
            ),
        ],
      ),
    );
    return [pane == null ? card : Expanded(child: card)];
  }

  Widget _composer() => Padding(
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
                            switch (transcriptSelection?.text ??
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
                      cacheWidth: (52 * MediaQuery.devicePixelRatioOf(context))
                          .round(),
                    ),
                  ),
                ),
                subtitle: w.provider['supportsImageInput'] == true
                    ? null
                    : const Text('Choose Claude or OpenAI to send this image.'),
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
