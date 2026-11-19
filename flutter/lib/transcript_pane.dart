import 'dart:math';

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:material_ui/material_ui.dart';

import 'page_surface.dart';
import 'relay_api.dart';
import 'workspace_style.dart';

/// Desktop chat panel only: opens and closes the video transcript pane.
class TranscriptBar extends StatelessWidget {
  const TranscriptBar({super.key, required this.open, required this.onToggle});
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onToggle,
    child: Container(
      padding: const EdgeInsets.fromLTRB(18, 7, 14, 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: line)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Transcript',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Icon(
            open ? Icons.expand_less : Icons.expand_more,
            size: 18,
            color: muted,
            semanticLabel: open ? 'Hide transcript' : 'Show transcript',
          ),
        ],
      ),
    ),
  );
}

/// Desktop chat panel only: the transcript of the video in a Browser tab.
/// Selected text becomes the next question's selection.
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
  final focus = FocusNode();
  Json? transcript;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.browser.loadTranscript();
      if (mounted) setState(() => transcript = result);
    } catch (e) {
      if (mounted) setState(() => error = e is StateError ? e.message : '$e');
    }
  }

  void _selected(SelectedContent? content) {
    final text = content?.plainText.trim() ?? '';
    // Moving focus to the composer clears the visible selection; the text
    // stays the question's selection until the user selects here again.
    if (text.isEmpty && !focus.hasFocus) return;
    widget.onSelected(
      text.isEmpty ? null : text.substring(0, min(text.length, 4000)),
    );
  }

  @override
  void dispose() {
    focus.dispose();
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
            Text(error!, style: const TextStyle(fontSize: 12, color: muted)),
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
    // A press in the pane starts over, so clicking without dragging clears the
    // selection kept for the question.
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kPrimaryButton) widget.onSelected(null);
      },
      child: SelectionArea(
        focusNode: focus,
        onSelectionChanged: _selected,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${loaded['language']}',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
              for (final paragraph in '${loaded['text']}'.split('\n'))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    paragraph,
                    style: const TextStyle(fontSize: 13, height: 1.45),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
