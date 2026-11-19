import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show ScrollDirection, SelectedContent;
import 'package:material_ui/material_ui.dart';

import 'browser_transcript.dart';
import 'page_surface.dart';
import 'relay_api.dart';

/// Desktop chat panel only: opens and closes the video transcript pane.
class TranscriptBar extends StatelessWidget {
  const TranscriptBar({super.key, required this.open, required this.onToggle});
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        decoration: BoxDecoration(
          border: open
              ? Border(bottom: BorderSide(color: colors.outline))
              : null,
        ),
        child: Row(
          children: [
            Icon(Icons.subtitles_outlined, size: 15, color: colors.primary),
            const SizedBox(width: 7),
            const Expanded(
              child: Text(
                'Transcript',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            Icon(
              open ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: colors.onSurfaceVariant,
              semanticLabel: open ? 'Hide transcript' : 'Show transcript',
            ),
          ],
        ),
      ),
    );
  }
}

/// Desktop chat panel only: the transcript of the video in a Browser tab.
/// Selected text becomes the next question's selection. While the pane is
/// open it highlights the paragraph being played and scrolls to it, until the
/// user scrolls or selects here; **Follow video** resumes the scrolling.
class TranscriptPane extends StatefulWidget {
  const TranscriptPane({
    super.key,
    required this.browser,
    required this.onSelected,
  });
  final BrowserSurface browser;
  final ValueChanged<String?> onSelected;

  @override
  State<TranscriptPane> createState() => _TranscriptPaneState();
}

class _TranscriptPaneState extends State<TranscriptPane> {
  ColorScheme get colors => Theme.of(context).colorScheme;
  final focus = FocusNode();
  Json? transcript;
  String? error;
  List<String> paragraphs = const [];
  List<int> starts = const [];
  List<GlobalKey> keys = const [];
  // One flag per paragraph, so a highlight change rebuilds only the two
  // paragraphs whose highlight changes.
  List<ValueNotifier<bool>> lit = const [];
  int playing = -1;
  bool following = true, _reading = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.browser.loadTranscript();
      if (!mounted) return;
      setState(() {
        transcript = result;
        paragraphs = '${result['text']}'.split('\n');
        starts = paragraphStarts(paragraphs);
        keys = [for (final _ in paragraphs) GlobalKey()];
        lit = [for (final _ in paragraphs) ValueNotifier(false)];
      });
      _clock = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => _play(),
      );
      _play();
    } catch (e) {
      if (mounted) setState(() => error = e is StateError ? e.message : '$e');
    }
  }

  // An unknown time, such as during an ad or a reload, keeps the highlight.
  Future<void> _play() async {
    if (_reading) return;
    _reading = true;
    final seconds = await widget.browser.playbackTime().catchError(
      (Object _) => null,
    );
    _reading = false;
    if (!mounted || seconds == null) return;
    final index = starts.lastIndexWhere((start) => start <= seconds);
    if (index == playing) return;
    if (playing >= 0) lit[playing].value = false;
    if (index >= 0) lit[index].value = true;
    playing = index;
    if (following) _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final paragraph = playing < 0 ? null : keys[playing].currentContext;
    if (!mounted || !following || paragraph == null) return;
    Scrollable.ensureVisible(
      paragraph,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  });

  void _pause() {
    if (following) setState(() => following = false);
  }

  void _selected(SelectedContent? content) {
    final text = content?.plainText.trim() ?? '';
    // Moving focus to the composer clears the visible selection; the text
    // stays the question's selection until the user selects here again.
    if (text.isEmpty && !focus.hasFocus) return;
    if (text.isNotEmpty) _pause();
    widget.onSelected(
      text.isEmpty ? null : text.substring(0, min(text.length, 4000)),
    );
  }

  // A muted timestamp marks transcript text apart from the conversation's
  // replies; selecting the paragraph still copies it with its timestamp.
  Widget _paragraph(String text) {
    final time = RegExp(r'^\[[\d:]+\] ?').stringMatch(text) ?? '';
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: time,
            style: TextStyle(
              fontSize: 11,
              color: colors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          TextSpan(text: text.substring(time.length)),
        ],
      ),
      style: const TextStyle(fontSize: 13, height: 1.45),
    );
  }

  @override
  void dispose() {
    _clock?.cancel();
    focus.dispose();
    for (final flag in lit) {
      flag.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              error!,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            TextButton(
              onPressed: () {
                setState(() => error = null);
                _load();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final loaded = transcript;
    if (loaded == null) {
      return const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // A press in the pane starts over, so clicking without dragging clears
        // the selection kept for the question.
        Listener(
          onPointerDown: (event) {
            if (event.buttons == kPrimaryButton) widget.onSelected(null);
          },
          child: SelectionArea(
            focusNode: focus,
            onSelectionChanged: _selected,
            // Only the user's own scrolling has a direction; following doesn't.
            child: NotificationListener<UserScrollNotification>(
              onNotification: (scroll) {
                if (scroll.direction != ScrollDirection.idle) _pause();
                return false;
              },
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        '${loaded['language']}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    for (var i = 0; i < paragraphs.length; i++)
                      Padding(
                        key: keys[i],
                        padding: const EdgeInsets.only(top: 4),
                        // Every paragraph is built, not only the visible ones,
                        // and a highlight changes only its colour, so a
                        // selection survives scrolling and highlight changes.
                        // Each paragraph paints once into its own layer, which
                        // scrolling only moves.
                        child: RepaintBoundary(
                          child: ValueListenableBuilder(
                            valueListenable: lit[i],
                            // A faint accent: primaryContainer matches the pane.
                            builder: (context, on, text) => DecoratedBox(
                              decoration: BoxDecoration(
                                color: on
                                    ? colors.primary.withValues(alpha: .14)
                                    : null,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: text,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: _paragraph(paragraphs[i]),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Outside the Listener, so pressing it keeps the question's selection.
        if (!following)
          Positioned(
            right: 12,
            bottom: 10,
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() => following = true);
                _reveal();
              },
              style: OutlinedButton.styleFrom(
                backgroundColor: colors.surface,
                foregroundColor: colors.primary,
                side: BorderSide(color: colors.outline),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              icon: const Icon(Icons.subtitles_outlined, size: 14),
              label: const Text('Follow video', style: TextStyle(fontSize: 11)),
            ),
          ),
      ],
    );
  }
}
