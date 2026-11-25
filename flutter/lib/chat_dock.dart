import 'package:material_ui/material_ui.dart';

import 'workspace.dart';
import 'workspace_style.dart';

/// Where chat is: open, chat only, its width and whether the transcript is
/// open. It saves [open] when it differs from the last saved value, and the
/// width when a drag ends. Each change notifies its listeners even when it
/// leaves everything as it was, as the shell's `setState` did when these were
/// its fields, so the shell redraws as often as before.
class ChatLayout extends ChangeNotifier {
  ChatLayout(this._open, this._width, this._saveOpen, this._saveWidth)
    : _savedOpen = _open;
  final Future<void> Function(bool)? _saveOpen;
  final Future<void> Function(double)? _saveWidth;
  bool _open, _savedOpen;
  bool _only = false;
  bool _transcriptOpen = false;
  double _width;

  /// Chat shows: docked beside the page on a desktop, a sheet on a phone.
  bool get open => _open;

  /// Chat fills the workspace in place of the page.
  bool get only => _only;

  /// Chat's share of a desktop window's width, before the dock clamps it.
  double get width => _width;

  /// The YouTube transcript is open above the conversation.
  bool get transcriptOpen => _transcriptOpen;

  /// Saves [open] when it differs from the last saved value, so chat reopens
  /// as it was left. The shell calls it once per build, as before: chat can
  /// close and reopen within one frame (a tab change that ends an area
  /// selection on a phone while an agent presentation closes chat), and that
  /// saves nothing.
  void saveOpenIfChanged() {
    if (_open != _savedOpen) {
      _savedOpen = _open;
      _saveOpen?.call(_open);
    }
  }

  /// The page shows again: chat only ends, and with [closeChat], for a phone
  /// whose chat sheet would cover the page, chat closes.
  void showPage({bool closeChat = false}) {
    _only = false;
    if (closeChat) _open = false;
    notifyListeners();
  }

  /// Chat opens, as the compact bar, a chosen conversation or the end of an
  /// area selection that moved it aside.
  void openChat() {
    _open = true;
    notifyListeners();
  }

  /// Chat closes, on a phone after an app opens or a new tab.
  void closeChat() {
    _open = false;
    notifyListeners();
  }

  /// Toggle chat: opens or closes chat, and ends chat only.
  void toggle() {
    _open = !_open;
    _only = false;
    notifyListeners();
  }

  /// Expand conversation, or Show workspace: chat only starts or ends, with
  /// chat open.
  void toggleOnly() {
    _only = !_only;
    _open = true;
    notifyListeners();
  }

  /// Chat only, from the workspace menu.
  void showChatOnly() {
    _only = true;
    _open = true;
    notifyListeners();
  }

  /// Opens or closes the YouTube transcript.
  void toggleTranscript() {
    _transcriptOpen = !_transcriptOpen;
    notifyListeners();
  }

  /// The divider moved; the width is saved when the drag ends.
  void resize(double width) {
    _width = width;
    notifyListeners();
  }

  /// The divider drag ended: saves the width.
  void resizeEnded() => _saveWidth?.call(_width);
}

/// Chat docked beside the [page] on a desktop, or a sheet over it on a phone
/// with a compact bar while closed, sliding as [layout] changes. The [panel]
/// is mounted only while chat shows or slides; it stays built but hidden while
/// a page fills the [screen].
class ChatDock extends StatelessWidget {
  const ChatDock(
    this.layout,
    this.workspace,
    this.size,
    this.screen,
    this.page,
    this.panel, {
    super.key,
  });
  final ChatLayout layout;
  final Workspace workspace;
  final BoxConstraints size;
  final bool screen;
  final Widget page;
  final Widget panel;
  Workspace get w => workspace;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final desktop = size.maxWidth >= wideWorkspace;
    final minFraction = (320 / size.maxWidth).clamp(.2, .5);
    final fraction = layout.width.clamp(minFraction, .5);
    final panelWidth = desktop ? size.maxWidth * fraction : size.maxWidth;
    final target = layout.only
        ? 2.0
        : layout.open
        ? 1.0
        : 0.0;
    final divider = MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => layout.resize(
          (fraction - details.delta.dx / size.maxWidth).clamp(minFraction, .5),
        ),
        onHorizontalDragEnd: (_) => layout.resizeEnded(),
        child: ColoredBox(color: colors.outline),
      ),
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: target),
      duration: workspaceMotion(context),
      curve: Curves.easeOutCubic,
      child: ExcludeFocus(excluding: !layout.open, child: panel),
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
                child: ExcludeFocus(excluding: layout.only, child: page),
              ),
            ),
            if (!desktop && reveal < 1 && !screen)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: ExcludeFocus(
                  excluding: layout.open,
                  child: IgnorePointer(
                    ignoring: layout.open,
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
                    ignoring: !layout.open,
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
            onPressed: layout.openChat,
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
}
