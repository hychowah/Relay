import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'browser_connection.dart';
import 'browser_transcript.dart';
import 'relay_api.dart';
import 'web_page.dart';
import 'windows_web_view.dart';
import 'workspace.dart';
import 'conversation_history.dart';
import 'provider_settings.dart';
import 'workspace_dialogs.dart';
import 'app_library.dart';
import 'app_servers.dart';
import 'app_updates.dart';
import 'conversation_view.dart';
import 'workspace_style.dart';
import 'workspace_tabs.dart';
import 'page_surface.dart';
import 'region_capture.dart';
import 'split_layout.dart';
import 'stored_data.dart';
import 'tab_memory.dart';
import 'tab_preview.dart';
import 'window_capture.dart';
import 'bug_reports.dart';
import 'capture_flight.dart';
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
  final address = TextEditingController();
  final addressFocus = FocusNode();
  bool pickedSuggestion = false, addressWasFocused = false;

  /// The inline fill-in: what the user typed, the whole address shown, with
  /// the filled-in rest selected after the typed text, and the page's URL.
  ({String typed, String text, String url})? fill;

  /// The last edit was a deletion or a paste, or Esc removed the fill-in
  /// (which also hides the list); each lasts until the user's next edit.
  bool noFill = false, escaped = false;

  /// The latest suggestions request, kept so that filling in, which changes
  /// the text but not the query, does not ask again until the page changes.
  ({String query, Future<List<_Suggestion>> pages})? asked;
  final messagesScroll = ScrollController();
  Timer? saveTimer;
  ({String appId, Uint8List bytes})? capture;
  bool capturing = false, reportingBug = false;
  ({WorkspaceTab tab, ui.Image image, bool reopenChat})? selecting;
  // The composer's thumbnail, and the captured picture on its way there.
  final captureSlot = GlobalKey();
  OverlayEntry? flight;
  late bool chatOpen = widget.initialChatOpen, savedChatOpen = chatOpen;
  bool chatOnly = false;
  bool transcriptOpen = false;

  /// The pane a tab is being dragged over and the side it would take.
  (WorkspaceTab, SplitSide)? dropping;
  ({String pane, String text, String page})? transcriptSelection;
  late double chatWidth = widget.initialChatWidth;
  int lastPresentation = 0;
  String? lastPageUrl;

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
    _lifecycle.dispose();
    tabMemory.dispose();
    saveTimer?.cancel();
    unawaited(widget.saveDraft(draft.text));
    draft.dispose();
    address.dispose();
    addressFocus.dispose();
    messagesScroll.dispose();
    selecting?.image.dispose();
    flight
      ?..remove()
      ..dispose();
    w.removeListener(_changed);
    w.recorder.removeListener(_changed);
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

  void _finishCapture(CapturedRegion? region) {
    final current = selecting;
    if (current == null) return;
    _land();
    setState(() {
      selecting = null;
      if (current.reopenChat) chatOpen = true;
      if (region == null) return;
      capture = (appId: current.tab.appId!, bytes: region.png);
      if (MediaQuery.disableAnimationsOf(context)) return;
      // The flight keeps its own handle on the frame, so the tool's handle
      // is released as before.
      final frame = current.image.clone();
      flight = OverlayEntry(
        builder: (_) => CaptureFlight(
          frame: frame,
          source: region.source,
          from: region.area,
          slot: captureSlot,
          onLanded: _land,
        ),
      );
      Overlay.of(context).insert(flight!);
    });
    // Let the overlay leave the tree before its frame is released.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => current.image.dispose(),
    );
  }

  /// Ends the flight; the composer's thumbnail shows from here on.
  void _land() {
    final entry = flight;
    if (entry == null) return;
    setState(() => flight = null);
    entry
      ..remove()
      ..dispose();
  }

  Future<void> _send() async {
    final text = draft.text;
    if (text.trim().isEmpty || w.busy) return;
    final attachment = capture;
    try {
      await w.send(
        text,
        capture: attachment,
        selection: transcriptSelection?.text,
      );
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

  Future<void> _recordBug() async {
    if (!w.recorder.recording) {
      w.recorder.start();
      return;
    }
    // Another click while a report is captured or asked about does nothing;
    // a second capture would clear the first one's page pictures.
    if (reportingBug) return;
    reportingBug = true;
    // The recording goes on while the user describes the bug; this marks
    // where the reproduction ended.
    w.recorder.action('stop pressed');
    try {
      // Capture before the dialog so the picture shows what the user saw.
      Uint8List? screenshot;
      try {
        screenshot = await captureWindow(context);
      } catch (_) {
        /* The report is still useful without a picture. */
      }
      if (!mounted) return;
      final size = MediaQuery.sizeOf(context);
      // Release builds strip Size.toString, so write the numbers out.
      final window = '${size.width.round()} × ${size.height.round()}';
      final answer = await askBugReport(context, w.recorder.events.length);
      if (answer == null) return;
      if (!answer.save) {
        w.recorder.stop();
        return;
      }
      final file = await w.saveBugReport(
        answer.description,
        category: answer.category,
        screenshot: screenshot,
        client: {
          'app': widget.updates?.installedLabel,
          'window': window,
          'chatOpen': chatOpen,
          'chatOnly': chatOnly,
          'chatWidth': chatWidth,
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Report saved: $file')));
      }
    } finally {
      reportingBug = false;
    }
  }

  Future<void> _menu(String action) async {
    if (action != 'record') w.recorder.action('menu', {'item': action});
    try {
      switch (action) {
        case 'record':
          await _recordBug();
        case 'reports':
          await showDialog<void>(
            context: context,
            builder: (_) => BugReportsDialog(api: w.api),
          );
        case 'servers':
          await showDialog<void>(
            context: context,
            builder: (_) => AppServersDialog(api: w.api),
          );
        case 'stored':
          await showDialog<void>(
            context: context,
            builder: (_) => StoredDataDialog(api: w.api),
          );
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
          await w.refreshApps();
          if (!mounted) return;
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
                    await w.saveSession();
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
      fill = null;
      asked = null;
      address.text = url == 'about:blank' ? '' : url ?? '';
    }
    // Several controls open or close chat; the panel reopens as it was left.
    if (chatOpen != savedChatOpen) {
      savedChatOpen = chatOpen;
      widget.saveChatOpen?.call(chatOpen);
    }
    // A fullscreen page takes the whole screen when its tab shows alone; in
    // split view it fills only its own pane. Leaving the screen for any other
    // reason, such as another tab opening, also ends the page's fullscreen.
    w.splitShown = MediaQuery.sizeOf(context).width >= 900;
    final inSplit = w.splitShown && w.shownSplit != null;
    final active = w.active?.page?.browser;
    final full = active?.fullScreen == true && !inSplit ? active : null;
    if (full != onScreen) {
      unawaited(onScreen?.fillScreen(false));
      unawaited(full?.fillScreen(true));
      onScreen = full;
    }
    final screen = full != null;
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
                  final page = LayoutBuilder(
                    builder: (context, area) =>
                        _pages(area.biggest, size.maxWidth >= 900),
                  );
                  return _panels(size, page, screen);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A Browser tab's bar, at the top of its own pane. Only the selected tab's
  /// bar takes input: another pane's tint takes the first click and selects
  /// that pane, so these buttons always act on the selected tab. A narrow
  /// pane's bar leaves out Go and the PDF zoom, which Enter and a pinch do,
  /// and the VPN button's label.
  Widget _browserBar(WorkspaceTab tab) => LayoutBuilder(
    builder: (context, size) => ClipRect(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: _barControls(tab, wide: size.maxWidth >= 480)),
      ),
    ),
  );

  List<Widget> _barControls(WorkspaceTab tab, {required bool wide}) {
    final browser = tab.page?.browser;
    return [
      IconButton(
        tooltip: 'Back',
        onPressed: browser?.canGoBack == true
            ? () => w.browserAction('back')
            : null,
        icon: const Icon(Icons.arrow_back),
      ),
      IconButton(
        tooltip: 'Forward',
        onPressed: browser?.canGoForward == true
            ? () => w.browserAction('forward')
            : null,
        icon: const Icon(Icons.arrow_forward),
      ),
      IconButton(
        tooltip: 'Reload',
        onPressed: () => w.browserAction('reload'),
        icon: const Icon(Icons.refresh),
      ),
      if (Platform.isMacOS) _vpnSwitch(tab, label: wide),
      Expanded(child: tab == w.active ? _addressField() : _addressShown(tab)),
      if (wide)
        IconButton(
          tooltip: 'Go',
          onPressed: () => _go(_addressTarget),
          icon: const Icon(Icons.arrow_forward),
        ),
      ..._readingControls(tab, zoom: wide),
    ];
  }

  /// Another pane's address, drawn as the address field draws it.
  Widget _addressShown(WorkspaceTab tab) {
    final url = tab.page?.url;
    final text = url == null || url == 'about:blank' ? '' : url;
    return InputDecorator(
      decoration: _addressDecoration,
      isEmpty: text.isEmpty,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    );
  }

  // Desktop (macOS) only: a quiet icon while the tab uses the Mac's own
  // network, a filled "VPN" button while it goes through NordVPN in WSL;
  // without its label in a narrow bar.
  Widget _vpnSwitch(WorkspaceTab tab, {required bool label}) {
    final on = tab.vpn;
    final tooltip = on
        ? 'VPN on: through NordVPN in WSL'
        : "VPN off: the Mac's own network";
    if (!on) {
      return IconButton(
        tooltip: tooltip,
        onPressed: w.toggleVpn,
        icon: const Icon(Icons.vpn_lock_outlined),
      );
    }
    if (!label) {
      return IconButton.filled(
        tooltip: tooltip,
        onPressed: w.toggleVpn,
        icon: const Icon(Icons.vpn_lock),
      );
    }
    return Tooltip(
      message: tooltip,
      child: FilledButton.icon(
        onPressed: w.toggleVpn,
        icon: const Icon(Icons.vpn_lock, size: 18),
        label: const Text('VPN'),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
      ),
    );
  }

  // Desktop only: zoom for a PDF, which shows in the Mac's own PDF viewer,
  // and Highlight for the text selected on any page of a Browser tab.
  List<Widget> _readingControls(WorkspaceTab tab, {required bool zoom}) {
    final browser = tab.page?.browser;
    final selection = tab.page?.context?['selection'];
    final selected = selection is String && selection.isNotEmpty;
    return [
      if (zoom && browser?.pdf == true) ...[
        IconButton(
          tooltip: 'Zoom out',
          onPressed: () => w.browserAction('zoomOut'),
          icon: const Icon(Icons.zoom_out),
        ),
        IconButton(
          tooltip: 'Zoom in',
          onPressed: () => w.browserAction('zoomIn'),
          icon: const Icon(Icons.zoom_in),
        ),
        IconButton(
          tooltip: 'Fit to width',
          onPressed: () => w.browserAction('zoomFit'),
          icon: const Icon(Icons.fit_screen),
        ),
      ],
      if (browser?.canHighlight == true)
        IconButton(
          tooltip: selected
              ? 'Highlight the selected text'
              : 'Select text on the page to highlight it',
          onPressed: selected ? () => w.browserAction('highlight') : null,
          icon: const Icon(Icons.border_color),
        ),
    ];
  }

  /// What the address bar opens: the suggested page's own URL while its
  /// filled-in text is shown, selected or accepted with the caret, since the
  /// text drops its scheme, `www.` and final `/`; otherwise the text as typed.
  String get _addressTarget =>
      address.text == fill?.text ? fill!.url : address.text;

  /// Opens [text] from the address bar; the page it lands on counts as typed.
  Future<void> _go(String text) async {
    final page = w.active?.page;
    await w.navigate(text);
    if (mounted && w.error == null && page != null && widget.browserHistory) {
      w.api.browserTyped(page.url);
    }
  }

  // Suggestions appear only once the user changes the address the app wrote.
  // Their first option stands for the typed text and is not listed, so Enter
  // opens what was typed, or the filled-in page, until the arrow keys move to
  // a page. The server
  // answers as the user types; RawAutocomplete drops an answer once the text
  // has changed again, and until then the earlier list stays, so the typed
  // text option always reads the field rather than the text it was made for.
  // As in Chrome, the best page's address also fills in after the typed text;
  // the query stays what the user typed, so the fill-in asks for nothing new.
  Widget _addressField() => RawAutocomplete<_Suggestion>(
    textEditingController: address,
    focusNode: addressFocus,
    optionsBuilder: (value) async {
      final query = value.text == fill?.text ? fill!.typed : value.text;
      if (!widget.browserHistory ||
          escaped ||
          query == lastPageUrl ||
          query.trim().isEmpty) {
        return const [];
      }
      if (asked?.query != query) {
        asked = (query: query, pages: w.api.browserSuggestions(query));
      }
      final pages = await asked!.pages;
      // A failed request also answers nothing; ask again next time.
      if (pages.isEmpty) asked = null;
      if (mounted) _fillIn(query, pages);
      return [if (pages.isNotEmpty) _typedText, ...pages];
    },
    displayStringForOption: (option) =>
        option == _typedText ? address.text : option.url,
    // Enter on the typed text option is opened by onSubmitted.
    onSelected: (option) {
      addressFocus.unfocus();
      if (option == _typedText) return;
      pickedSuggestion = true;
      _go(option.url);
    },
    fieldViewBuilder: (context, controller, focus, submit) => Builder(
      builder: (context) => Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (intent) {
              if (_filled(address.value)) {
                escaped = true;
                address.value = TextEditingValue(
                  text: fill!.typed,
                  selection: TextSelection.collapsed(
                    offset: fill!.typed.length,
                  ),
                );
              }
              return Actions.maybeInvoke(context, intent);
            },
          ),
        },
        // A tap focuses the field as the field's own request, which
        // selectAllOnFocus skips, and the tap has placed the caret by the
        // time onTap runs; so a click that focuses the field selects here.
        child: Listener(
          onPointerDown: (_) => addressWasFocused = addressFocus.hasFocus,
          child: TextField(
            controller: controller,
            focusNode: focus,
            decoration: _addressDecoration,
            inputFormatters: [
              TextInputFormatter.withFunction(
                (before, now) => _edited(context, before, now),
              ),
            ],
            onTap: () {
              if (!addressWasFocused) {
                address.selection = TextSelection(
                  baseOffset: 0,
                  extentOffset: address.text.length,
                );
              }
            },
            // Each change of the text returns the highlight to the typed text.
            onChanged: (_) => Actions.maybeInvoke(
              context,
              const AutocompleteFirstOptionIntent(),
            ),
            onSubmitted: (_) {
              pickedSuggestion = false;
              submit();
              if (!pickedSuggestion) _go(_addressTarget);
            },
          ),
        ),
      ),
    ),
    optionsViewBuilder: (context, select, options) {
      final highlighted = AutocompleteHighlightedOption.of(context) - 1;
      return Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Material(
            color: colors.surface,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colors.outline),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(6),
              children: [
                for (final (index, option) in options.skip(1).indexed)
                  ListTile(
                    dense: true,
                    selected: index == highlighted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                    title: Text(
                      option.title.isEmpty ? option.url : option.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: option.title.isEmpty
                        ? null
                        : Text(
                            option.url,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () => select(option),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  bool _filled(TextEditingValue value) =>
      value.text == fill?.text &&
      value.selection.start == fill!.typed.length &&
      value.selection.end == value.text.length &&
      value.composing.isCollapsed;

  /// Fills in the best page after [query] once its answer arrives, if the
  /// user is still editing [query], as typed or filled in, with the caret at
  /// the end and no input method composing.
  void _fillIn(String query, List<_Suggestion> pages) {
    final value = address.value;
    final atEnd =
        value.selection.isCollapsed &&
        value.selection.baseOffset == value.text.length &&
        value.composing.isCollapsed;
    final typed = _filled(value) ? fill!.typed : (atEnd ? value.text : null);
    if (noFill || typed != query || !addressFocus.hasFocus) return;
    final best = pages.firstOrNull;
    final text = best == null ? null : inlineCompletion(query, best.url);
    fill = text == null ? null : (typed: query, text: text, url: best!.url);
    final shown = text ?? query;
    if (shown != value.text) {
      address.value = TextEditingValue(
        text: shown,
        selection: TextSelection(
          baseOffset: query.length,
          extentOffset: shown.length,
        ),
      );
    }
  }

  /// Applies the user's own edits. Typing the next filled-in character keeps
  /// the rest filled in without waiting for the server; any other edit drops
  /// the fill-in, and a deletion or a paste fills nothing in until the next
  /// edit, as in Chrome. Moving only the caret is not an edit.
  TextEditingValue _edited(
    BuildContext context,
    TextEditingValue before,
    TextEditingValue now,
  ) {
    final shown = fill, typed = now.text, cut = before.selection;
    // The characters the edit put in place of the selection; several at once
    // with no input method composing are a paste.
    final added = typed.length - before.text.length + cut.end - cut.start;
    escaped = false;
    if (shown != null &&
        _filled(before) &&
        now.composing.isCollapsed &&
        now.selection.isCollapsed &&
        now.selection.baseOffset == typed.length &&
        added == 1 &&
        typed.length < shown.text.length &&
        shown.text.toLowerCase().startsWith(typed.toLowerCase())) {
      noFill = false;
      fill = (
        typed: typed,
        text: typed + shown.text.substring(typed.length),
        url: shown.url,
      );
      // The text stays the same, so onChanged does not run.
      Actions.maybeInvoke(context, const AutocompleteFirstOptionIntent());
      return TextEditingValue(
        text: fill!.text,
        selection: TextSelection(
          baseOffset: typed.length,
          extentOffset: fill!.text.length,
        ),
      );
    }
    fill = null;
    noFill =
        before.composing.isCollapsed &&
        now.composing.isCollapsed &&
        (added < 0 || added > 1 || added == 0 && !cut.isCollapsed);
    return now;
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
        tab.isBrowser && tab.page?.browser?.fullScreen != true ? _barHeight : 0;
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
                chatOnly = false;
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
          if (selecting case final s? when s.tab == tab)
            below(
              tab,
              RegionCapture(
                key: ValueKey(s.image),
                image: s.image,
                onDone: _finishCapture,
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
                onServers: tab.isBrowser ? null : () => _menu('servers'),
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
                        onPressed: () => _menu('servers'),
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
                child: _browserBar(tab),
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

  /// Chat stays built but hidden while a page fills the [screen].
  Widget _panels(BoxConstraints size, Widget page, bool screen) {
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
        child: ColoredBox(color: colors.outline),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target),
      duration: workspaceMotion(context),
      curve: Curves.easeOutCubic,
      child: ExcludeFocus(excluding: !chatOpen, child: _chat(desktop)),
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
              right: desktop && !screen ? (panelWidth + 6) * reveal : 0,
              child: Offstage(
                offstage: expand == 1 && !screen,
                child: ExcludeFocus(excluding: chatOnly, child: page),
              ),
            ),
            if (!desktop && reveal < 1 && !screen)
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
                child: Offstage(
                  offstage: screen,
                  child: IgnorePointer(
                    ignoring: !chatOpen,
                    child: Row(
                      children: [
                        if (desktop)
                          SizedBox(
                            width: gutter,
                            height: height,
                            child: divider,
                          ),
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
              final split = MediaQuery.sizeOf(context).width >= 900
                  ? w.shownSplit
                  : null;
              return ValueListenableBuilder(
                valueListenable: tabMemory,
                builder: (context, memory, _) => WorkspaceTabs(
                  tabs: List.of(w.tabs),
                  selected: chatOnly ? null : split ?? w.active,
                  split: split?.layout.tabs,
                  draggable: MediaQuery.sizeOf(context).width >= 900,
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
                    setState(() => chatOnly = false);
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
          tooltip: w.recorder.recording
              ? 'Recording. Stop and save'
              : 'Record a bug or request',
          onPressed: () => _menu('record'),
          icon: w.recorder.recording
              ? const Icon(Icons.fiber_manual_record, color: Colors.red)
              : Icon(
                  Icons.fiber_manual_record_outlined,
                  color: colors.onSurfaceVariant,
                ),
        ),
        IconButton(
          tooltip: 'Toggle chat',
          onPressed: () => setState(() {
            w.recorder.action(chatOpen ? 'close chat' : 'open chat');
            chatOpen = !chatOpen;
            chatOnly = false;
          }),
          icon: Icon(
            Icons.view_sidebar_outlined,
            color: chatOpen ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
        MenuAnchor(
          animated: !MediaQuery.disableAnimationsOf(context),
          builder: (context, controller, child) => IconButton(
            tooltip: 'Workspace menu',
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: Badge(
              isLabelVisible: widget.updates?.ready ?? false,
              child: const Icon(Icons.tune_rounded),
            ),
          ),
          menuChildren: [
            const MenuLabel('WORKSPACE'),
            _menuItem('library', 'App library', Icons.grid_view_rounded),
            _menuItem('bots', 'Bots', Icons.smart_toy_outlined),
            _menuItem('memory', 'Memory', Icons.bookmarks_outlined),
            _menuItem('servers', 'App servers', Icons.dns_outlined),
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
            SubmenuButton(
              leadingIcon: const Icon(Icons.contrast_rounded, size: 17),
              menuChildren: [
                for (final (mode, label) in const [
                  (ThemeMode.system, 'System'),
                  (ThemeMode.light, 'Light'),
                  (ThemeMode.dark, 'Dark'),
                ])
                  MenuItemButton(
                    leadingIcon: Icon(
                      widget.themeMode == mode ? Icons.check : null,
                      size: 16,
                    ),
                    onPressed: () => widget.onThemeMode(mode),
                    child: Text(label),
                  ),
              ],
              child: const Text('Appearance'),
            ),
            CheckboxMenuButton(
              value: w.newestTabFirst,
              onChanged: (value) => w.setNewestTabFirst(value!),
              child: const Text('Newest tab first'),
            ),
            _menuItem('stored', 'Stored data', Icons.storage_rounded),
            if (widget.updates case final updates?)
              MenuItemButton(
                leadingIcon: Badge(
                  isLabelVisible: updates.ready,
                  child: const Icon(Icons.system_update_alt_rounded, size: 17),
                ),
                onPressed: () => _menu('updates'),
                child: Text(updates.ready ? 'Update ready' : 'Updates'),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 5),
              child: Divider(),
            ),
            const MenuLabel('DEVELOPMENT'),
            _menuItem('reports', 'Reports', Icons.bug_report_outlined),
            if (Platform.isMacOS)
              CheckboxMenuButton(
                value: tabMemory.on,
                onChanged: (value) => setState(() => tabMemory.show(value!)),
                child: const Text('Show tab memory'),
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
    final pane = video != null && transcriptOpen ? '${tab!.id} $video' : null;
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
            open: transcriptOpen,
            onToggle: () => setState(() => transcriptOpen = !transcriptOpen),
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
          if (capture case final attachment?)
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                dense: true,
                leading: SizedBox(
                  key: captureSlot,
                  width: 52,
                  height: 38,
                  // Hidden while the captured picture is still flying here.
                  child: Opacity(
                    opacity: flight == null ? 1 : 0,
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

class NewTabPage extends StatefulWidget {
  const NewTabPage({
    super.key,
    required this.apps,
    required this.onChoose,
    required this.onShow,
    required this.devices,
    required this.onOpenDevice,
  });
  final List<WorkspaceApp> apps;
  final Future<void> Function(WorkspaceApp) onChoose;
  final Future<void> Function() onShow;

  /// The user's other devices with the tabs each saved last.
  final Future<List<Json>> Function() devices;
  final Future<void> Function(Json tabs) onOpenDevice;
  @override
  State<NewTabPage> createState() => _NewTabPageState();
}

class _NewTabPageState extends State<NewTabPage> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  String search = '';
  late final Future<List<Json>> devices = widget.devices();
  @override
  void initState() {
    super.initState();
    unawaited(widget.onShow());
  }

  /// What a saved tab shows: a website's host, or its app or report name.
  String? _tabName(Json tab) {
    if (tab['split'] != null) return null;
    final url = tab['url'] as String?;
    final host = url == null ? null : Uri.tryParse(url)?.host;
    if (host != null && host.isNotEmpty) return host;
    final source = tab['source'] as Map?;
    return source?['title'] as String? ??
        widget.apps.where((app) => app.id == tab['appId']).firstOrNull?.name;
  }

  Widget _devices() => FutureBuilder(
    future: devices,
    builder: (context, snapshot) {
      final found = snapshot.data ?? const [];
      if (found.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 18),
          Text(
            'ON YOUR OTHER DEVICES',
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          for (final device in found)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: colors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: colors.outline),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => widget.onOpenDevice(device['tabs'] as Json),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Icon(
                          Icons.devices_rounded,
                          size: 20,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Open ${device['name']}\'s tabs here',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                [
                                  timeAgo(
                                    DateTime.fromMillisecondsSinceEpoch(
                                      device['updatedAt'] as int,
                                    ),
                                  ),
                                  ...{
                                    for (final tab
                                        in ((device['tabs'] as Json)['tabs']
                                                as List)
                                            .cast<Json>())
                                      ?_tabName(tab),
                                  },
                                ].join(' · '),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
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
        ],
      );
    },
  );

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
                Text(
                  'YOUR WORKSPACE',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'What would you like to open?',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 10),
                Text(
                  'Your apps, connected by one conversation.',
                  style: TextStyle(
                    fontSize: 14,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 28),
                TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Search apps',
                    prefixIcon: const Icon(Icons.search_rounded, size: 19),
                    fillColor: colors.surface,
                  ),
                  onChanged: (value) => setState(() => search = value),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) widget.onChoose(matches.first);
                  },
                ),
                const SizedBox(height: 28),
                Text(
                  'APPS',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                for (final app in matches)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: colors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: colors.outline),
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
                                  color: colors.primaryContainer,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  app.isBrowser
                                      ? Icons.language_rounded
                                      : Icons.grid_view_rounded,
                                  size: 20,
                                  color: colors.primary,
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
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
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
                  Text(
                    'No matching apps.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                if (search.trim().isEmpty) _devices(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The address-bar text that completes [typed] with [url] inline, or null
/// when [url], without its scheme and `www.`, does not continue [typed]. The
/// typed characters stay as typed, and a bare site has no trailing `/`.
String? inlineCompletion(String typed, String url) {
  final prefix = RegExp(r'^(https?://)?(www\.)?', caseSensitive: false);
  final start = typed.replaceFirst(prefix, '');
  var address = url.replaceFirst(prefix, '');
  if (RegExp(r'^[^/]+/$').hasMatch(address)) {
    address = address.substring(0, address.length - 1);
  }
  if (start.isEmpty ||
      address.length <= start.length ||
      !address.toLowerCase().startsWith(start.toLowerCase())) {
    return null;
  }
  return typed + address.substring(start.length);
}

/// The height of a Browser tab's bar above its page. It is fixed, so a page
/// keeps its size whichever pane is selected.
const _barHeight = 46.0;

const _addressDecoration = InputDecoration(
  hintText: 'Search or enter a web address',
  isDense: true,
  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
);

/// An address-bar suggestion: a visited page, or [_typedText].
typedef _Suggestion = ({String url, String title});
const _Suggestion _typedText = (url: '', title: '');
