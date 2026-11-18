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
    this.sessionRestored,
    required this.saveConversation,
  });
  Json? pendingSession;
  final Future<void> Function()? sessionRestored;
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
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_starting) return;
    _starting = true;
    _poll?.cancel();
    try {
      error = null;
      await loadConfig();
      if (pendingSession != null && await restoreSession(pendingSession!)) {
        await sessionRestored?.call();
        pendingSession = null;
        _restoredTabs.clear();
      }
      await refresh();
      _poll = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(refresh()),
      );
    } catch (e) {
      error = e.toString();
      changed();
    } finally {
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

  Future<void> loadBots() async {
    bots = await api.bots();
    changed();
  }

  Future<void> changeEffort(String? effort) async {
    if (conversationId == null) await newConversation();
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
    final tab = WorkspaceTab();
    tabs.add(tab);
    select(tab);
  }

  void closeTab(WorkspaceTab tab) {
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
      final view = app.isBrowser ? null : await api.appView(id, tab.id);
      if (!tabs.contains(tab)) return tab;
      tab.page = pages(
        PageSpec(
          id: tab.id,
          appId: id,
          name: tab.name,
          sessionId: browserSessionId,
          relayOrigin: api.origin,
          appView: view,
        ),
        (manualChange) {
          if (manualChange && active == tab) _manual();
          changed();
        },
      );
      changed();
      await tab.page!.ready.timeout(const Duration(seconds: 20));
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
    if (manual) _manual();
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
      final view = await api.appView(appId, tab.id, source: report['source']);
      if (revision != _manualRevision || !tabs.contains(tab)) {
        throw StateError('View changed while opening the source.');
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
        (manualChange) {
          if (manualChange && active == tab) _manual();
          changed();
        },
      );
      changed();
      await tab.page!.ready.timeout(const Duration(seconds: 20));
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

  Future<void> browserAction(String action) async {
    _manual();
    try {
      await active?.page?.browser?.browserAction(action);
    } catch (e) {
      error = e.toString();
    }
    changed();
  }

  Future<void> navigate(String text) async {
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
        conversationId = await api.createConversation(selectedBotId);
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
    final id = await api.createConversation(changeBot ? botId : selectedBotId);
    selectedBotId = changeBot ? botId : selectedBotId;
    await selectConversation(id);
  }

  Future<void> selectConversation(String? id) async {
    _manual();
    _conversationRevision++;
    conversationId = id;
    snapshot = null;
    status = null;
    error = null;
    changed();
    await saveConversation(id);
    await refresh();
  }

  Future<void> trashConversation(String id) async {
    await api.trashConversation(id);
    if (conversationId == id) await selectConversation(null);
  }

  Future<void> restoreConversation(String id) => api.restoreConversation(id);

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

  Json session() => {
    'active': active == null ? -1 : tabs.indexOf(active!),
    'tabs': tabs
        .map(
          (tab) => {
            'appId': tab.appId,
            'url': tab.page?.url,
            'source': tab.report?['source'],
            'context': tab.page?.context,
          },
        )
        .toList(),
  };

  Future<bool> restoreSession(Json saved) async {
    final previousActive = active;
    final items = (saved['tabs'] as List).cast<Json>();
    var complete = true;
    for (var index = 0; index < items.length; index++) {
      // A reconnect retries only unfinished tabs, preserving later user changes.
      if (_restoredTabs.containsKey(index)) continue;
      final item = items[index];
      String? restoringId;
      try {
        if (item['appId'] == null) {
          newTab();
          _restoredTabs[index] = active!;
          continue;
        }
        final app = apps.where((app) => app.id == item['appId']).firstOrNull;
        if (app == null) {
          throw StateError('App ${item['appId']} is unavailable.');
        }
        final existing = tabs
            .where((tab) => tab.appId == item['appId'])
            .firstOrNull;
        if (existing != null && !existing.isBrowser) {
          _restoredTabs[index] = existing;
          continue;
        }
        newTab();
        restoringId = active!.id;
        final tab = item['source'] != null
            ? await openSource(item['source'] as Json)
            : await openApp(app);
        if (tab.error != null) throw StateError(tab.error!);
        if (tab.isBrowser &&
            item['url'] != null &&
            item['url'] != 'about:blank') {
          await tab.page!.browser!.navigate(item['url'] as String);
        } else if (tab.report == null && item['context'] != null) {
          final context = item['context'] as Json;
          final result = await tab.page!.presentOnCurrentView({
            'id': _uuid.v4(),
            'kind': 'present',
            'intent': {
              for (final key in ['viewId', 'state', 'targetIds', 'source'])
                if (context[key] != null) key: context[key],
            },
          });
          if (result['status'] != 'applied') {
            throw StateError(
              result['error'] as String? ?? 'View restoration failed.',
            );
          }
        }
        _restoredTabs[index] = tab;
      } catch (e) {
        complete = false;
        for (final tab in tabs.where((tab) => tab.id == restoringId).toList()) {
          closeTab(tab);
        }
        error = 'Could not restore a tab: $e';
      }
    }
    final selected = previousActive ?? _restoredTabs[saved['active']];
    if (selected != null && tabs.contains(selected)) select(selected);
    changed();
    return complete;
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
