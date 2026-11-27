import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'address_bar.dart';
import 'area_capture.dart';
import 'chat_dock.dart';
import 'chat_panel.dart';
import 'page_stack.dart';
import 'browser_connection.dart';
import 'relay_api.dart';
import 'web_page.dart';
import 'windows_web_view.dart';
import 'workspace.dart';
import 'workspace_menu.dart';
import 'app_library.dart';
import 'app_updates.dart';
import 'workspace_style.dart';
import 'workspace_tabs.dart';
import 'page_surface.dart';
import 'tab_memory.dart';
import 'tab_preview.dart';
import 'window_capture.dart';

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

  /// Desktop only. Browser tabs keep the server's browsing history, and the
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
  late final address = AddressInput(w, history: widget.browserHistory);
  late final layout = ChatLayout(
    widget.initialChatOpen,
    widget.initialChatWidth,
    widget.saveChatOpen,
    widget.saveChatWidth,
  );
  late final capture = AreaCapture(context, w, layout);
  late final chat = ChatInput(
    w,
    layout,
    capture,
    widget.initialDraft,
    widget.saveDraft,
  );
  late final actions = ShellActions(
    context,
    w,
    widget.updates,
    layout,
    chat.flush,
    _selectedConversation,
  );

  int lastPresentation = 0;

  /// The page shown on the whole screen.
  BrowserSurface? onScreen;
  // The conversation last opened on another device opens here too.
  late final AppLifecycleListener _lifecycle;

  /// Desktop only (macOS).
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
    chat.addListener(_redraw);
    layout.addListener(_redraw);
    capture.addListener(_redraw);
    w.addListener(_changed);
    w.recorder.addListener(_changed);
    widget.updates?.addListener(_changed);
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
    chat.dispose();
    address.dispose();
    layout.dispose();
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

  void _selectedConversation() {
    chat.clear();
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
                  chat.follow(w.active, desktop: desktop);
                  final page = PageStack(
                    w,
                    desktop,
                    address,
                    capture,
                    layout,
                    _choose,
                    () => actions.run(WorkspaceAction.servers),
                    _redraw,
                  );
                  return ChatDock(
                    layout,
                    w,
                    size,
                    screen,
                    page,
                    ChatPanel(
                      w,
                      chat,
                      layout,
                      capture,
                      actions,
                      _selectedConversation,
                      _newConversation,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
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
                  onMove: w.moveTab,
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
}
