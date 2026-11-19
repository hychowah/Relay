import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'page_surface.dart';
import 'relay_api.dart';

const _uuid = Uuid();

class WorkspaceTab {
  WorkspaceTab({
    String? id,
    this.appId,
    this.name = 'New tab',
    this.isBrowser = false,
  }) : id = id ?? _uuid.v4();
  final String id;
  final String? appId;
  final String name;
  String token = _uuid.v4();
  PageSurface? page;
  Json? report;
  String? error;
  final bool isBrowser;
  String get title => page?.title ?? name;
}

class Workspace extends ChangeNotifier {
  Workspace({
    required this.api,
    required this.deviceId,
    required this.pages,
    this.conversationId,
    this.pendingSession,
    this.storeSession,
    required this.saveConversation,
  }) {
    api.recorder = recorder;
  }
  final recorder = BugRecorder();
  Json? pendingSession;
  final Future<void> Function(Json)? storeSession;
  // Saving waits for the first restore attempt, so a start that is offline or
  // still opening tabs cannot replace the previous run's tabs. After that the
  // open tabs are the record: a tab that failed to restore is retried by
  // Reconnect in this run and is not kept for the next one.
  late bool _sessionLoaded = pendingSession == null;
  String? _savedSession;
  Future<void> _sessionWrite = Future.value();
  final _restoredTabs = <int, WorkspaceTab>{};
  bool _starting = false;
  final RelayApi api;
  final String deviceId;
  final PageFactory pages;
  final Future<void> Function(String?) saveConversation;
  final String windowId = _uuid.v4(), browserSessionId = _uuid.v4();
  final tabs = <WorkspaceTab>[];
  List<WorkspaceApp> apps = [];
  ConversationSnapshot? snapshot;
  List<ChatMessage> get messages => snapshot?.messages ?? const [];
  Json provider = {};
  List<Json> bots = [];
  String? selectedBotId;

  /// Thinking effort chosen before the first message; the conversation is
  /// saved with it when that message is sent.
  String? draftEffort;
  String? get effort => conversationId == null
      ? draftEffort
      : snapshot?.conversation?.reasoningEffort;
  Json? get activeBot =>
      bots.where((bot) => bot['id'] == selectedBotId).firstOrNull;
  List<WorkspaceApp> get allowedApps => selectedBotId == null
      ? apps
      : apps
            .where(
              (app) => ((activeBot?['appIds'] as List?) ?? []).contains(app.id),
            )
            .toList();
  WorkspaceTab? active;
  String? conversationId, error, status, _commandId;
  bool sending = false, _polling = false, _disposed = false;
  int _manualRevision = 0;
  int presentations = 0;
  bool includeContext = true;
  int _conversationRevision = 0;
  Timer? _poll;
  final _processed = <String>{};
  final _contextlessRequests = <String, int>{};
  ConversationRun? get running =>
      snapshot?.runs.where((run) => run.status == 'running').firstOrNull;
  bool get busy => sending || running != null;
  String? _lastError, _lastTabError;
  void changed() {
    if (_disposed) return;
    if (error != null && error != _lastError) {
      recorder.add('error', {'message': error});
    }
    final tabError = active?.error;
    if (tabError != null && tabError != _lastTabError) {
      recorder.add('error', {'tab': active!.title, 'message': tabError});
    }
    _lastError = error;
    _lastTabError = tabError;
    unawaited(saveSession());
    notifyListeners();
  }

  void _pageChanged(WorkspaceTab tab, bool manualChange) {
    if (manualChange) {
      recorder.action('page changed', {
        'tab': tab.title,
        'url': tab.page?.url,
        'context': tab.page?.context,
      });
      if (active == tab) _manual();
    }
    changed();
  }

  /// Stores the open tabs when they differ from the last save, and completes
  /// when the latest save has been written.
  Future<void> saveSession() {
    if (_sessionLoaded && storeSession != null) {
      final current = session();
      final encoded = jsonEncode(current);
      if (encoded != _savedSession) {
        _savedSession = encoded;
        _sessionWrite = storeSession!(current);
      }
    }
    return _sessionWrite;
  }

  Future<void> start() async {
    if (_starting) return;
    _starting = true;
    _poll?.cancel();
    Future<bool>? restoring;
    try {
      error = null;
      await loadConfig();
      // The restore adds and selects the tabs before its first await, so the
      // conversation loads while their pages do.
      if (pendingSession != null) restoring = restoreSession(pendingSession!);
      await refresh();
      _poll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(refresh()),
      );
      if (restoring != null) {
        if (await restoring) {
          pendingSession = null;
          _restoredTabs.clear();
        }
        _sessionLoaded = true;
        await saveSession();
      }
    } catch (e) {
      error = e.toString();
      changed();
    } finally {
      if (restoring != null) {
        // After an error, saving still waits for the restore to end.
        await restoring.catchError((_) => false);
        _sessionLoaded = true;
      }
      _starting = false;
    }
  }

  Future<void> loadConfig() async {
    final config = await api.config();
    apps = config.apps;
    provider = config.provider;
    await loadBots();
    changed();
  }

  /// Reads the registered apps again, so places that choose an app show
  /// registration changes without Reconnect. Open tabs are left as they are;
  /// when the backend cannot be reached the current list stays.
  Future<void> refreshApps() async {
    try {
      apps = (await api.config()).apps;
      changed();
    } catch (_) {}
  }

  Future<void> loadBots() async {
    bots = await api.bots();
    changed();
  }

  Future<void> changeEffort(String? effort) async {
    recorder.action('change thinking effort', {'effort': effort});
    if (conversationId == null) {
      draftEffort = effort;
      changed();
      return;
    }
    await api.setEffort(conversationId!, effort);
    await refresh();
  }

  void _manual() {
    _manualRevision++;
    if (_commandId != null) active?.page?.cancel(_commandId!);
    active?.token = _uuid.v4();
  }

  void select(WorkspaceTab tab, {bool manual = true}) {
    if (manual) _manual();
    final token = active?.token ?? tab.token;
    active = tab;
    tab.token = manual ? _uuid.v4() : token;
    changed();
  }

  void newTab() {
    recorder.action('new tab');
    final tab = WorkspaceTab();
    tabs.add(tab);
    select(tab);
  }

  void closeTab(WorkspaceTab tab) {
    recorder.action('close tab', {'tab': tab.title});
    final index = tabs.indexOf(tab);
    if (active == tab) {
      _manual();
      active = null;
    }
    tabs.remove(tab);
    tab.page?.dispose();
    if (active == null && tabs.isNotEmpty) {
      select(tabs[(index - 1).clamp(0, tabs.length - 1)]);
    }
    changed();
  }

  Future<void> chooseApp(
    WorkspaceApp app,
    Future<void> Function(String) showLibrary,
  ) async {
    if (app.opensInLibrary) {
      await showLibrary(app.id);
    } else {
      await openApp(app);
    }
  }

  Future<WorkspaceTab> openApp(
    WorkspaceApp app, {
    bool manual = true,
    bool requireAppView = false,
  }) async {
    final id = app.id;
    if (manual) recorder.action('open app', {'appId': id});
    final blank = active?.appId == null ? active : null;
    final existing = app.isBrowser
        ? null
        : tabs.where((tab) => tab.appId == id).firstOrNull;
    if (existing != null) {
      if (blank != null) tabs.remove(blank);
      if (existing.error == null &&
          !(requireAppView && existing.report != null)) {
        select(existing, manual: manual);
        return existing;
      }
      existing.page?.dispose();
      existing.page = null;
      existing.error = null;
      existing.report = null;
    }
    final tab =
        existing ??
        WorkspaceTab(
          id: blank?.id,
          appId: id,
          name: app.name,
          isBrowser: app.isBrowser,
        );
    if (existing == null) {
      if (blank == null) {
        tabs.add(tab);
      } else {
        tabs[tabs.indexOf(blank)] = tab;
      }
    }
    select(tab, manual: manual);
    try {
      await _loadPage(tab);
    } catch (e) {
      tab.error = e.toString();
      changed();
      rethrow;
    }
    return tab;
  }

  Future<WorkspaceTab> openSource(
    Json source, {
    Json? focus,
    bool manual = true,
  }) async {
    if (manual) {
      recorder.action('open source', {'source': source, 'focus': focus});
      _manual();
    }
    final revision = _manualRevision;
    final appId = source['appId'] as String;
    final report = await api.readSource(source);
    if (revision != _manualRevision) {
      throw StateError('View changed while opening the source.');
    }
    var tab = tabs.where((tab) => tab.appId == appId).firstOrNull;
    if (tab == null) {
      final blank = active?.appId == null ? active : null;
      tab = WorkspaceTab(
        id: blank?.id,
        appId: appId,
        name: report['source']['title'] as String,
      );
      if (blank != null) {
        tabs[tabs.indexOf(blank)] = tab;
      } else {
        tabs.add(tab);
      }
    }
    tab.page?.dispose();
    tab.page = null;
    tab.report = report;
    tab.error = null;
    if (manual) presentations++;
    select(tab, manual: false);
    try {
      if (!await _loadPage(tab, revision: revision)) {
        throw StateError('View changed while opening the source.');
      }
      if (focus != null && revision == _manualRevision) {
        final result = await tab.page!.present({
          'id': _uuid.v4(),
          'kind': 'navigate',
          'source': report['source'],
          ...focus,
        });
        if (result['status'] != 'applied') {
          throw StateError(
            result['error'] as String? ?? 'Source focus could not be applied.',
          );
        }
      }
    } catch (e) {
      tab.error = e.toString();
    }
    changed();
    return tab;
  }

  /// Creates [tab]'s page from its app view and report, and waits for it to
  /// load. Returns false, without a page, when the tab was closed or the view
  /// changed after [revision] while the app view was requested.
  Future<bool> _loadPage(WorkspaceTab tab, {int? revision}) async {
    final appId = tab.appId!;
    final report = tab.report;
    final view = tab.isBrowser
        ? null
        : await api.appView(appId, tab.id, source: report?['source']);
    if (!tabs.contains(tab) ||
        (revision != null && revision != _manualRevision)) {
      return false;
    }
    tab.page = pages(
      PageSpec(
        id: tab.id,
        appId: appId,
        name: tab.name,
        sessionId: browserSessionId,
        relayOrigin: api.origin,
        appView: view,
        report: report,
      ),
      (manualChange) => _pageChanged(tab, manualChange),
    );
    changed();
    await tab.page!.ready.timeout(const Duration(seconds: 20));
    return true;
  }

  Future<void> browserAction(String action) async {
    recorder.action('browser $action');
    _manual();
    try {
      await active?.page?.browser?.browserAction(action);
    } catch (e) {
      error = e.toString();
    }
    changed();
  }

  Future<void> navigate(String text) async {
    recorder.action('browser navigate', {'address': text});
    try {
      _manual();
      await active?.page?.browser?.navigate(text);
      error = null;
    } catch (e) {
      error = e.toString();
    }
    changed();
  }

  Future<Json> readBrowser(String tabId) async {
    final browser = tabs
        .where((tab) => tab.id == tabId)
        .firstOrNull
        ?.page
        ?.browser;
    if (browser == null) {
      throw StateError('The requested browser tab is closed.');
    }
    return browser.read();
  }

  Future<void> send(
    String text, {
    ({String appId, Uint8List bytes})? capture,
  }) async {
    if (text.trim().isEmpty || busy) return;
    recorder.action('send message', {
      'text': text,
      'tab': active?.title,
      'includeContext': includeContext,
      'capture': capture != null,
    });
    sending = true;
    error = null;
    changed();
    try {
      final tab = active;
      final viewToken = tab?.token;
      final revision = _manualRevision;
      final browser = tab?.page?.browser;
      if (capture != null) {
        if (provider['supportsImageInput'] != true) {
          throw StateError(
            'Choose Claude on a capture-enabled Relay backend to send this image.',
          );
        }
        if (!allowedApps.any((app) => app.id == capture.appId)) {
          throw StateError('This bot cannot access the captured app.');
        }
      }
      final permitted = allowedApps.any((app) => app.id == tab?.appId);
      if (permitted && includeContext) {
        if (browser != null) {
          await browser.read();
        } else {
          await tab?.page?.refreshSelection();
        }
      }
      if (conversationId == null) {
        conversationId = await api.createConversation(
          selectedBotId,
          draftEffort,
        );
        draftEffort = null;
        await saveConversation(conversationId!);
      }
      final context = permitted && includeContext
          ? tab?.page?.messageContext(tab.appId!, viewToken)
          : null;
      final source = context?.savedSource;
      if (source != null) await api.savedReport(source);
      final runId = await api.sendMessage(conversationId!, {
        'text': text.trim(),
        'deviceId': deviceId,
        'tabId': windowId,
        ...?context?.fields,
        if (capture != null)
          'capture': {
            'appId': capture.appId,
            'png': base64Encode(capture.bytes),
          },
      });
      if (context?.anchorsView != true) _contextlessRequests[runId] = revision;
      // A poll that started before the message was sent cannot show the new
      // run, so the workspace would look idle. Wait for it, then fetch again.
      await _inFlight;
      await refresh();
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      sending = false;
      changed();
    }
  }

  Future<void> stop() async {
    if (running == null) return;
    recorder.action('stop reply', {'runId': running!.id});
    if (_commandId != null) active?.page?.cancel(_commandId!);
    try {
      await api.cancelRun(running!.id);
      await refresh();
    } catch (e) {
      error = e.toString();
      changed();
    }
  }

  Future<List<Conversation>> conversations({
    String query = '',
    bool trash = false,
  }) => api.conversations(query: query, trash: trash);

  Future<void> newConversation({String? botId, bool changeBot = false}) async {
    recorder.action('new conversation', {
      'botId': changeBot ? botId : selectedBotId,
    });
    // The conversation is saved when its first message is sent, so an empty
    // one never reaches history or needs cleaning up.
    selectedBotId = changeBot ? botId : selectedBotId;
    await selectConversation(null);
  }

  Future<void> selectConversation(String? id) async {
    recorder.action('open conversation', {'conversationId': id});
    _manual();
    _conversationRevision++;
    conversationId = id;
    draftEffort = null;
    snapshot = null;
    status = null;
    error = null;
    changed();
    await saveConversation(id);
    await refresh();
  }

  Future<void> trashConversation(String id) async {
    recorder.action('trash conversation', {'conversationId': id});
    await api.trashConversation(id);
    if (conversationId == id) await selectConversation(null);
  }

  Future<void> restoreConversation(String id) {
    recorder.action('restore conversation', {'conversationId': id});
    return api.restoreConversation(id);
  }

  Future<void>? _inFlight;
  Future<void> refresh() {
    if (_polling || conversationId == null || _disposed) return Future.value();
    return _inFlight = _refresh();
  }

  Future<void> _refresh() async {
    _polling = true;
    final id = conversationId!;
    final revision = _conversationRevision;
    try {
      final next = await api.snapshot(id);
      if (_disposed || revision != _conversationRevision) return;
      snapshot = next;
      selectedBotId = next.conversation?.botId;
      final tool = next.tools
          .where((tool) => tool.status == 'running')
          .lastOrNull;
      final progress = tool?.progress ?? [];
      status = running == null
          ? null
          : progress.isNotEmpty
          ? progress.last['message'] as String?
          : tool?.name ?? 'Thinking…';
      changed();
      for (final command in next.commands) {
        if (command.status == 'pending' &&
            command.deviceId == deviceId &&
            command.tabId == windowId &&
            _processed.add(command.id)) {
          await _present(command);
        }
      }
    } catch (e) {
      if (_disposed || revision != _conversationRevision) return;
      if (e is RelayApiException && e.status == 404) {
        conversationId = null;
        snapshot = null;
        status = null;
        await saveConversation(null);
      }
      error = e.toString();
      changed();
    } finally {
      _polling = false;
    }
  }

  Future<void> _ack(
    ViewCommand command,
    String result, {
    Json? context,
    String? detail,
  }) async {
    await api.acknowledge(command.id, {
      'deviceId': deviceId,
      'tabId': windowId,
      'status': result,
      if (result == 'applied' || (result == 'failed' && context != null))
        'viewToken': active?.token,
      'context': ?context,
      'error': ?detail,
    });
  }

  Future<void> _present(ViewCommand command) async {
    final unchanged = command.expectedViewToken == null
        ? _contextlessRequests[command.runId] == _manualRevision
        : command.expectedViewToken == active?.token;
    if (!unchanged) {
      await _ack(command, 'stale');
      return;
    }
    final revision = _manualRevision;
    recorder.add('agent view command', {'command': command.json});
    presentations++;
    changed();
    _commandId = command.id;
    try {
      if (command.kind == 'navigate') {
        final target = await openSource(command.source!, manual: false);
        if (_manualRevision != revision) {
          await _ack(command, 'stale');
          return;
        }
        if (target.error != null) throw StateError(target.error!);
        final result = await target.page!.present(command.json);
        await _ack(
          command,
          _manualRevision == revision ? result['status'] as String : 'stale',
          detail: result['error'] as String?,
        );
        return;
      }
      var target = active;
      final newSurface =
          target?.appId != command.appId || target?.report != null;
      if (newSurface) {
        final app = apps.where((app) => app.id == command.appId).firstOrNull;
        if (app == null) throw StateError('App is unavailable.');
        target = await openApp(app, manual: false, requireAppView: true);
      }
      await target?.page?.ready.timeout(const Duration(seconds: 20));
      if (_manualRevision != revision || active != target) {
        await _ack(command, 'stale');
        return;
      }
      final page = target!.page!;
      final result = newSurface
          ? await page.presentOnCurrentView(command.json)
          : await page.present(command.json);
      if (_manualRevision != revision || active != target) {
        await _ack(command, 'stale');
        return;
      }
      if (result['status'] == 'applied' ||
          (result['status'] == 'failed' && result['context'] != null)) {
        target.token = _uuid.v4();
      }
      await _ack(
        command,
        result['status'] as String,
        context: result['context'] as Json?,
        detail: result['error'] as String?,
      );
    } catch (e) {
      await _ack(
        command,
        _manualRevision != revision ? 'stale' : 'failed',
        detail: e.toString(),
      );
    } finally {
      _commandId = null;
      changed();
    }
  }

  /// Stops the recording and saves it on the server; returns the report file.
  Future<String> saveBugReport(
    String description, {
    Uint8List? screenshot,
    Json client = const {},
  }) async {
    recorder.stop();
    try {
      final saved = await api.saveBugReport({
        'description': description,
        ...recorder.report,
        'client': {
          ...client,
          'deviceId': deviceId,
          'windowId': windowId,
          'provider': provider,
        },
        'conversationId': conversationId,
        'workspace': session(),
        if (screenshot != null) 'screenshot': base64Encode(screenshot),
      });
      return saved['file'] as String;
    } catch (_) {
      recorder.resume();
      rethrow;
    }
  }

  Json session() => {
    'active': active == null ? -1 : tabs.indexOf(active!),
    'tabs': tabs
        .map(
          (tab) => {
            'appId': tab.appId,
            'url': tab.page?.url,
            'source': tab.report?['source'],
            'context': _viewIntent(tab.page?.context),
          },
        )
        .toList(),
  };

  // The parts of a page's context that reopen its view. The rest, such as
  // selected text, is not kept.
  static Json? _viewIntent(Json? context) => context == null
      ? null
      : {
          for (final key in ['viewId', 'state', 'targetIds', 'source'])
            if (context[key] != null) key: context[key],
        };

  /// Adds every saved tab and selects the saved active one before any page
  /// loads, then loads all pages together without selecting them, so the user
  /// keeps whatever tab they choose meanwhile.
  Future<bool> restoreSession(Json saved) async {
    final items = (saved['tabs'] as List).cast<Json>();
    final loads = <Future<bool>>[];
    var complete = true;
    for (var index = 0; index < items.length; index++) {
      // A reconnect retries only unfinished tabs, preserving later user changes.
      if (_restoredTabs.containsKey(index)) continue;
      final item = items[index];
      final appId = item['appId'] as String?;
      if (appId == null) {
        tabs.add(_restoredTabs[index] = WorkspaceTab());
        continue;
      }
      final app = apps.where((app) => app.id == appId).firstOrNull;
      if (app == null) {
        complete = false;
        error = 'Could not restore a tab: App $appId is unavailable.';
        continue;
      }
      final existing = app.isBrowser
          ? null
          : tabs.where((tab) => tab.appId == appId).firstOrNull;
      if (existing != null) {
        _restoredTabs[index] = existing;
        continue;
      }
      // A source tab takes its name from the saved source, so it can open
      // before its report is read.
      final source = item['source'] as Json?;
      final tab = WorkspaceTab(
        appId: appId,
        name: source?['title'] as String? ?? app.name,
        isBrowser: app.isBrowser,
      );
      tabs.add(_restoredTabs[index] = tab);
      loads.add(_restoreTab(index, item, tab));
    }
    final selected = _restoredTabs[saved['active']] ?? tabs.lastOrNull;
    if (active == null && selected != null && tabs.contains(selected)) {
      select(selected);
    }
    changed();
    final restored = await Future.wait(loads);
    return complete && !restored.contains(false);
  }

  Future<bool> _restoreTab(int index, Json item, WorkspaceTab tab) async {
    try {
      final source = item['source'] as Json?;
      if (source != null) tab.report = await api.readSource(source);
      if (!await _loadPage(tab)) return true;
      if (tab.isBrowser) {
        // A Browser tab that never left its start page has nothing to reopen.
        if (item['url'] != null && item['url'] != 'about:blank') {
          await tab.page!.browser!.navigate(item['url'] as String);
        }
      } else if (tab.report == null && item['context'] != null) {
        final result = await tab.page!.presentOnCurrentView({
          'id': _uuid.v4(),
          'kind': 'present',
          'intent': _viewIntent(item['context'] as Json),
        });
        if (result['status'] != 'applied') {
          throw StateError(
            result['error'] as String? ?? 'View restoration failed.',
          );
        }
      }
      changed();
      return true;
    } catch (e) {
      // A tab the user closed while it loaded stays closed.
      if (!tabs.contains(tab)) return true;
      _restoredTabs.remove(index);
      error = 'Could not restore a tab: $e';
      closeTab(tab);
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    for (final tab in tabs) {
      tab.page?.dispose();
    }
    api.close();
    super.dispose();
  }
}
