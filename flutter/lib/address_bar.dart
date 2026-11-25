import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'workspace.dart';

/// The selected tab's address as the user edits it in the Browser bar. It
/// outlives the bar, which is rebuilt as the selected tab, its pane or
/// fullscreen changes, so an unsent edit stays until the selected page's
/// address changes. Call [follow] with the selected tab, of any kind, on every
/// shell build. With [history], the field suggests visited pages and Go
/// records the page it opens as typed.
class AddressInput {
  AddressInput(this.workspace, {this.history = false});
  final Workspace workspace;
  final bool history;
  Workspace get w => workspace;
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  bool _pickedSuggestion = false, _addressWasFocused = false;

  /// The inline fill-in: what the user typed, the whole address shown, with
  /// the filled-in rest selected after the typed text, and the page's URL.
  ({String typed, String text, String url})? _fill;

  /// The last edit was a deletion or a paste, or Esc removed the fill-in
  /// (which also hides the list); each lasts until the user's next edit.
  bool _noFill = false, _escaped = false;

  /// The latest suggestions request, kept so that filling in, which changes
  /// the text but not the query, does not ask again until the page changes.
  ({String query, Future<List<_Suggestion>> pages})? _asked;
  String? _lastPageUrl;
  bool _disposed = false;

  /// The field's text, for the bar's field to edit.
  TextEditingController get controller => _address;

  /// The field's focus, for the bar's field to take.
  FocusNode get focus => _addressFocus;

  /// Shows [tab]'s address, dropping any edit, fill-in and suggestions
  /// request, when it differs from the address last followed.
  void follow(WorkspaceTab? tab) {
    final url = _addressOf(tab);
    if (url != _lastPageUrl) {
      _lastPageUrl = url;
      _fill = null;
      _asked = null;
      _address.text = url == 'about:blank' ? '' : url ?? '';
    }
  }

  /// Releases the field's text and focus; a suggestions answer or a Go that
  /// finishes afterwards changes nothing.
  void dispose() {
    _disposed = true;
    _address.dispose();
    _addressFocus.dispose();
  }

  /// The pages to suggest for the field's [value]: none until the user changes
  /// the address the app wrote. When there are pages, the first option stands
  /// for the typed text. The best page also fills in after the typed text.
  Future<List<({String url, String title})>> suggestionsFor(
    TextEditingValue value,
  ) async {
    final query = value.text == _fill?.text ? _fill!.typed : value.text;
    if (!history || _escaped || query == _lastPageUrl || query.trim().isEmpty) {
      return const [];
    }
    if (_asked?.query != query) {
      _asked = (query: query, pages: w.api.browserSuggestions(query));
    }
    final pages = await _asked!.pages;
    // A failed request also answers nothing; ask again next time.
    if (pages.isEmpty) _asked = null;
    if (!_disposed) _fillIn(query, pages);
    return [if (pages.isNotEmpty) _typedText, ...pages];
  }

  /// The user picked [option] from the list. The typed text option opens
  /// through [submitted] instead.
  void picked(({String url, String title}) option) {
    _addressFocus.unfocus();
    if (option == _typedText) return;
    _pickedSuggestion = true;
    _go(option.url);
  }

  /// Esc puts back the typed text in place of the fill-in, and hides the list
  /// until the next edit.
  void escape() {
    if (_filled(_address.value)) {
      _escaped = true;
      _address.value = TextEditingValue(
        text: _fill!.typed,
        selection: TextSelection.collapsed(offset: _fill!.typed.length),
      );
    }
  }

  /// A pointer went down on the field; [tapped] then knows whether the tap
  /// focused it.
  void pointerDown() => _addressWasFocused = _addressFocus.hasFocus;

  /// A tap that focused the field selects all of its text.
  void tapped() {
    if (!_addressWasFocused) {
      _address.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _address.text.length,
      );
    }
  }

  /// Enter: [select] opens the highlighted page through [picked], if there is
  /// one; otherwise the field's address opens.
  void submitted(VoidCallback select) {
    _pickedSuggestion = false;
    select();
    if (!_pickedSuggestion) _go(_addressTarget);
  }

  /// The Go button: opens the field's address.
  void go() => _go(_addressTarget);

  /// Applies the user's own edits. Typing the next filled-in character keeps
  /// the rest filled in without waiting for the server; any other edit drops
  /// the fill-in, and a deletion or a paste fills nothing in until the next
  /// edit, as in Chrome. Moving only the caret is not an edit. Returns [now]
  /// itself unless the fill-in stays.
  TextEditingValue edited(TextEditingValue before, TextEditingValue now) {
    final shown = _fill, typed = now.text, cut = before.selection;
    // The characters the edit put in place of the selection; several at once
    // with no input method composing are a paste.
    final added = typed.length - before.text.length + cut.end - cut.start;
    _escaped = false;
    if (shown != null &&
        _filled(before) &&
        now.composing.isCollapsed &&
        now.selection.isCollapsed &&
        now.selection.baseOffset == typed.length &&
        added == 1 &&
        typed.length < shown.text.length &&
        shown.text.toLowerCase().startsWith(typed.toLowerCase())) {
      _noFill = false;
      _fill = (
        typed: typed,
        text: typed + shown.text.substring(typed.length),
        url: shown.url,
      );
      return TextEditingValue(
        text: _fill!.text,
        selection: TextSelection(
          baseOffset: typed.length,
          extentOffset: _fill!.text.length,
        ),
      );
    }
    _fill = null;
    _noFill =
        before.composing.isCollapsed &&
        now.composing.isCollapsed &&
        (added < 0 || added > 1 || added == 0 && !cut.isCollapsed);
    return now;
  }

  /// What the address bar opens: the suggested page's own URL while its
  /// filled-in text is shown, selected or accepted with the caret, since the
  /// text drops its scheme, `www.` and final `/`; otherwise the text as typed.
  String get _addressTarget =>
      _address.text == _fill?.text ? _fill!.url : _address.text;

  /// Opens [text] from the address bar; the page it lands on counts as typed.
  Future<void> _go(String text) async {
    final tab = w.active;
    // A loaded tab's page is the one Go loads in, even if a network switch
    // replaces it meanwhile; an unloaded tab gets its page from navigating.
    final loaded = tab?.unloaded == null ? tab?.page : null;
    await w.navigate(text);
    final page = loaded ?? tab?.page;
    if (!_disposed && w.error == null && page != null && history) {
      w.api.browserTyped(page.url);
    }
  }

  bool _filled(TextEditingValue value) =>
      value.text == _fill?.text &&
      value.selection.start == _fill!.typed.length &&
      value.selection.end == value.text.length &&
      value.composing.isCollapsed;

  /// Fills in the best page after [query] once its answer arrives, if the
  /// user is still editing [query], as typed or filled in, with the caret at
  /// the end and no input method composing.
  void _fillIn(String query, List<_Suggestion> pages) {
    final value = _address.value;
    final atEnd =
        value.selection.isCollapsed &&
        value.selection.baseOffset == value.text.length &&
        value.composing.isCollapsed;
    final typed = _filled(value) ? _fill!.typed : (atEnd ? value.text : null);
    if (_noFill || typed != query || !_addressFocus.hasFocus) return;
    final best = pages.firstOrNull;
    final text = best == null ? null : inlineCompletion(query, best.url);
    _fill = text == null ? null : (typed: query, text: text, url: best!.url);
    final shown = text ?? query;
    if (shown != value.text) {
      _address.value = TextEditingValue(
        text: shown,
        selection: TextSelection(
          baseOffset: query.length,
          extentOffset: shown.length,
        ),
      );
    }
  }
}

/// A Browser tab's bar, at the top of its own pane. Only the selected tab's
/// bar takes input: another pane's tint takes the first click and selects
/// that pane, so these buttons always act on the selected tab. A narrow
/// pane's bar leaves out Go and the PDF zoom, which Enter and a pinch do,
/// and the VPN button's label. The selected tab's bar edits [input]; another
/// pane's shows its tab's address.
class BrowserBar extends StatelessWidget {
  const BrowserBar(this.workspace, this.tab, this.input, {super.key});

  /// The height of a Browser tab's bar above its page. It is fixed, so a page
  /// keeps its size whichever pane is selected.
  static const height = 46.0;

  final Workspace workspace;
  final WorkspaceTab tab;
  final AddressInput input;
  Workspace get w => workspace;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => ClipRect(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: _barControls(context, wide: size.maxWidth >= 480)),
      ),
    ),
  );

  List<Widget> _barControls(BuildContext context, {required bool wide}) {
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
      Expanded(
        child: tab == w.active ? _addressField() : _addressShown(context),
      ),
      if (wide)
        IconButton(
          tooltip: 'Go',
          onPressed: input.go,
          icon: const Icon(Icons.arrow_forward),
        ),
      ..._readingControls(tab, zoom: wide),
    ];
  }

  /// Another pane's address, drawn as the address field draws it.
  Widget _addressShown(BuildContext context) {
    final url = _addressOf(tab);
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

  /// Desktop only (macOS). A quiet icon while the tab uses the Mac's own
  /// network, a filled "VPN" button while it goes through NordVPN in WSL;
  /// without its label in a narrow bar.
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

  /// Desktop only. Zoom for a PDF, which shows in the Mac's own PDF viewer,
  /// and Highlight for the text selected on any page of a Browser tab.
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
    textEditingController: input.controller,
    focusNode: input.focus,
    optionsBuilder: input.suggestionsFor,
    displayStringForOption: (option) =>
        option == _typedText ? input.controller.text : option.url,
    // Enter on the typed text option is opened by onSubmitted.
    onSelected: input.picked,
    fieldViewBuilder: (context, controller, focus, submit) => Builder(
      builder: (context) => Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (intent) {
              input.escape();
              return Actions.maybeInvoke(context, intent);
            },
          ),
        },
        // A tap focuses the field as the field's own request, which
        // selectAllOnFocus skips, and the tap has placed the caret by the
        // time onTap runs; so a click that focuses the field selects here.
        child: Listener(
          onPointerDown: (_) => input.pointerDown(),
          child: TextField(
            controller: controller,
            focusNode: focus,
            decoration: _addressDecoration,
            inputFormatters: [
              TextInputFormatter.withFunction((before, now) {
                final value = input.edited(before, now);
                // The fill-in stays and the text stays the same, so onChanged
                // does not run.
                if (!identical(value, now)) {
                  Actions.maybeInvoke(
                    context,
                    const AutocompleteFirstOptionIntent(),
                  );
                }
                return value;
              }),
            ],
            onTap: input.tapped,
            // Each change of the text returns the highlight to the typed text.
            onChanged: (_) => Actions.maybeInvoke(
              context,
              const AutocompleteFirstOptionIntent(),
            ),
            onSubmitted: (_) => input.submitted(submit),
          ),
        ),
      ),
    ),
    optionsViewBuilder: (context, select, options) {
      final colors = Theme.of(context).colorScheme;
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

/// A tab's address; an unloaded Browser tab keeps its own until it loads.
String? _addressOf(WorkspaceTab? tab) => tab?.unloaded?.url ?? tab?.page?.url;

const _addressDecoration = InputDecoration(
  hintText: 'Search or enter a web address',
  isDense: true,
  contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
);

/// An address-bar suggestion: a visited page, or [_typedText].
typedef _Suggestion = ({String url, String title});
const _Suggestion _typedText = (url: '', title: '');
