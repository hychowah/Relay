import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_library.dart';
import 'app_servers.dart';
import 'app_updates.dart';
import 'bug_reports.dart';
import 'chat_dock.dart';
import 'provider_settings.dart';
import 'shared_folders.dart';
import 'stored_data.dart';
import 'tab_memory.dart';
import 'window_capture.dart';
import 'workspace.dart';
import 'workspace_dialogs.dart';
import 'workspace_style.dart';

/// What the workspace menu and the shell's other controls run. Bug
/// recordings name each use by [name] (except `record`), so names never
/// change.
enum WorkspaceAction {
  record,
  reports,
  servers,
  stored,
  folders,
  provider,
  bots,
  memory,
  forward,
  library,
  updates,
  reconnect,
  chat,
}

/// Runs each [WorkspaceAction] for the workspace menu and the shell's other
/// controls: its dialog, recording and saving a bug report, installing an
/// update, reconnecting or showing chat only. It opens them through the
/// shell's context, so a step that would follow a closed shell is skipped.
class ShellActions {
  ShellActions(
    this._context,
    this.workspace,
    this._updates,
    this._layout,
    this._saveDraftNow,
    this._onConversationChosen,
  );
  final BuildContext _context;
  final Workspace workspace;
  final AppUpdates? _updates;
  final ChatLayout _layout;
  // The shell's draft, saved at once before an update restarts the app.
  final Future<void> Function() _saveDraftNow;
  final VoidCallback _onConversationChosen;
  Workspace get w => workspace;
  bool _reportingBug = false;

  Future<void> _recordBug() async {
    if (!w.recorder.recording) {
      w.recorder.start();
      return;
    }
    // Another click while a report is captured or asked about does nothing;
    // a second capture would clear the first one's page pictures.
    if (_reportingBug) return;
    _reportingBug = true;
    // The recording goes on while the user describes the bug; this marks
    // where the reproduction ended.
    w.recorder.action('stop pressed');
    try {
      // Capture before the dialog so the picture shows what the user saw.
      Uint8List? screenshot;
      try {
        screenshot = await captureWindow(_context);
      } catch (_) {
        /* The report is still useful without a picture. */
      }
      if (!_context.mounted) return;
      final size = MediaQuery.sizeOf(_context);
      // Release builds strip Size.toString, so write the numbers out.
      final window = '${size.width.round()} × ${size.height.round()}';
      final answer = await askBugReport(_context, w.recorder.events.length);
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
          'app': _updates?.installedLabel,
          'window': window,
          'chatOpen': _layout.open,
          'chatOnly': _layout.only,
          'chatWidth': _layout.width,
        },
      );
      if (_context.mounted) {
        ScaffoldMessenger.of(_context)
            .showSnackBar(SnackBar(content: Text('Report saved: $file')));
      }
    } finally {
      _reportingBug = false;
    }
  }

  /// Runs [action], noting it in a bug recording unless it is
  /// [WorkspaceAction.record]. A failure shows in the workspace's banner.
  Future<void> run(WorkspaceAction action) async {
    if (action != WorkspaceAction.record) {
      w.recorder.action('menu', {'item': action.name});
    }
    try {
      switch (action) {
        case WorkspaceAction.record:
          await _recordBug();
        case WorkspaceAction.reports:
          await showDialog<void>(
            context: _context,
            builder: (_) => BugReportsDialog(api: w.api),
          );
        case WorkspaceAction.servers:
          await showDialog<void>(
            context: _context,
            builder: (_) => AppServersDialog(api: w.api),
          );
        case WorkspaceAction.stored:
          await showDialog<void>(
            context: _context,
            builder: (_) => StoredDataDialog(api: w.api),
          );
        case WorkspaceAction.folders:
          await showDialog<void>(
            context: _context,
            builder: (_) => SharedFoldersDialog(api: w.api),
          );
        case WorkspaceAction.provider:
          await showDialog<void>(
            context: _context,
            builder: (_) => ProviderSettings(workspace: w),
          );
        case WorkspaceAction.bots:
          await showBots(_context, w, _onConversationChosen);
        case WorkspaceAction.memory:
          await showDialog<void>(
            context: _context,
            builder: (_) =>
                MemoryDialog(workspace: w, onSelected: _onConversationChosen),
          );
        case WorkspaceAction.forward:
          await showDialog<void>(
            context: _context,
            builder: (_) =>
                ForwardDialog(workspace: w, onSelected: _onConversationChosen),
          );
        case WorkspaceAction.library:
          await w.refreshApps();
          if (!_context.mounted) return;
          await showDialog<void>(
            context: _context,
            builder: (_) => AppLibrary(workspace: w),
          );
        case WorkspaceAction.updates:
          unawaited(_updates!.loadPreviews());
          await showDialog<void>(
            barrierDismissible: false,
            context: _context,
            builder: (_) => ListenableBuilder(
              listenable: w,
              builder: (_, _) => UpdateDialog(
                updates: _updates,
                busy: () => w.busy,
                install: () async {
                  if (w.busy) return;
                  await _updates.install(() async {
                    await w.api.checkIdleBeforeRestart(
                      w.deviceId,
                      w.windowId,
                      allowOffline:
                          _updates.returningToStable &&
                          w.api.origin != _updates.origin,
                    );
                    await _saveDraftNow();
                    await w.saveSession();
                  });
                },
              ),
            ),
          );
        case WorkspaceAction.reconnect:
          await w.start();
        case WorkspaceAction.chat:
          _layout.showChatOnly();
      }
    } catch (e) {
      w.error = e.toString();
      w.changed();
    }
  }
}

/// The toolbar's workspace menu: its actions, Appearance, Newest tab first
/// and the update entry, with a dot while an update is ready.
class WorkspaceMenu extends StatefulWidget {
  const WorkspaceMenu(
    this.actions,
    this.workspace,
    this.updates,
    this.themeMode,
    this.onThemeMode,
    this.tabMemory, {
    super.key,
  });
  final ShellActions actions;
  final Workspace workspace;
  final AppUpdates? updates;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeMode;

  /// Desktop only (macOS): what "Show tab memory" turns on.
  final TabMemory tabMemory;
  @override
  State<WorkspaceMenu> createState() => _WorkspaceMenuState();
}

// A state only so that "Show tab memory" redraws its check mark, as the
// shell's setState did.
class _WorkspaceMenuState extends State<WorkspaceMenu> {
  Workspace get w => widget.workspace;
  TabMemory get tabMemory => widget.tabMemory;

  @override
  Widget build(BuildContext context) => MenuAnchor(
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
      actionItem(
        widget.actions,
        WorkspaceAction.library,
        'App library',
        Icons.grid_view_rounded,
      ),
      actionItem(
        widget.actions,
        WorkspaceAction.bots,
        'Bots',
        Icons.smart_toy_outlined,
      ),
      actionItem(
        widget.actions,
        WorkspaceAction.memory,
        'Memory',
        Icons.bookmarks_outlined,
      ),
      actionItem(
        widget.actions,
        WorkspaceAction.servers,
        'App servers',
        Icons.dns_outlined,
      ),
      actionItem(
        widget.actions,
        WorkspaceAction.folders,
        'Shared folders',
        Icons.folder_outlined,
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 5),
        child: Divider(),
      ),
      const MenuLabel('CONNECTION'),
      actionItem(
        widget.actions,
        WorkspaceAction.provider,
        'Provider and model',
        Icons.tune_rounded,
      ),
      actionItem(
        widget.actions,
        WorkspaceAction.reconnect,
        'Reconnect',
        Icons.refresh_rounded,
      ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 5),
        child: Divider(),
      ),
      actionItem(
        widget.actions,
        WorkspaceAction.chat,
        'Chat only',
        Icons.chat_bubble_outline_rounded,
      ),
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
      actionItem(
        widget.actions,
        WorkspaceAction.stored,
        'Stored data',
        Icons.storage_rounded,
      ),
      if (widget.updates case final updates?)
        MenuItemButton(
          leadingIcon: Badge(
            isLabelVisible: updates.ready,
            child: const Icon(Icons.system_update_alt_rounded, size: 17),
          ),
          onPressed: () => widget.actions.run(WorkspaceAction.updates),
          child: Text(updates.ready ? 'Update ready' : 'Updates'),
        ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 5),
        child: Divider(),
      ),
      const MenuLabel('DEVELOPMENT'),
      actionItem(
        widget.actions,
        WorkspaceAction.reports,
        'Reports',
        Icons.bug_report_outlined,
      ),
      if (Platform.isMacOS)
        CheckboxMenuButton(
          value: tabMemory.on,
          onChanged: (value) => setState(() => tabMemory.show(value!)),
          child: const Text('Show tab memory'),
        ),
    ],
  );
}

/// A menu item that runs [action], disabled unless [enabled].
Widget actionItem(
  ShellActions actions,
  WorkspaceAction action,
  String label,
  IconData icon, {
  bool enabled = true,
}) => MenuItemButton(
  leadingIcon: Icon(icon, size: 17),
  onPressed: enabled ? () => actions.run(action) : null,
  child: Text(label),
);
