import 'dart:convert';

import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'relay_api.dart';
import 'workspace.dart';
import 'workspace_style.dart';

class ResponseTurn {
  final messages = <ChatMessage>[];
  final runs = <ConversationRun>[];
  final tools = <ToolRecord>[];
  final commands = <ViewCommand>[];
}

List<ResponseTurn> responseTurns(ConversationSnapshot snapshot) {
  final turns = <ResponseTurn>[];
  for (final message in snapshot.messages) {
    if (message.role == 'user' || turns.isEmpty) turns.add(ResponseTurn());
    turns.last.messages.add(message);
  }
  final runTurns = <String, ResponseTurn>{};
  for (final run in snapshot.runs) {
    if (turns.isEmpty) break;
    final turn =
        turns
            .where(
              (turn) =>
                  (turn.messages.first.createdAt ?? '').compareTo(
                    run.startedAt ?? '',
                  ) <=
                  0,
            )
            .lastOrNull ??
        turns.first;
    turn.runs.add(run);
    runTurns[run.id] = turn;
  }
  for (final tool in snapshot.tools) {
    runTurns[tool.runId]?.tools.add(tool);
  }
  for (final command in snapshot.commands) {
    runTurns[command.runId]?.commands.add(command);
  }
  return turns;
}

List<Json> responseSources(List<ToolRecord> tools) {
  final sources = <String, Json>{};
  for (final tool in tools) {
    final output = tool.output;
    if (output is! Map) continue;
    final found = tool.name == 'app_call'
        ? (output['sources'] as List? ?? [])
        : tool.name == 'app_read' && output['source'] != null
        ? [output['source']]
        : [];
    for (final raw in found) {
      final source = Map<String, dynamic>.from(raw as Map);
      sources[jsonEncode([
            source['appId'],
            source['resourceId'],
            source['revision'],
          ])] =
          source;
    }
  }
  return sources.values.toList();
}

Json? citedSource(String href, List<Json> sources) {
  final absolute = Uri.tryParse(href);
  if (absolute?.hasScheme == true) {
    return sources
        .where((s) => Uri.tryParse(s['sourceUrl'] as String) == absolute)
        .firstOrNull;
  }
  if (href.startsWith('//')) return null;
  final matches = sources.where((s) {
    if (s['sourceUrl'] == href) return true;
    final uri = Uri.tryParse(s['sourceUrl'] as String);
    if (uri == null) return false;
    return href.startsWith('#/')
        ? '#${uri.fragment}' == href
        : '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}${uri.hasFragment ? '#${uri.fragment}' : ''}' ==
              href.replaceFirst(RegExp(r'^\./'), '/');
  }).toList();
  return matches.length == 1 ? matches.first : null;
}

Json? sourceFocus(Json source, List<ViewCommand> commands) {
  for (final c in commands.reversed) {
    final presenting = c.kind == 'present';
    final shown = presenting ? c.intent!['source'] : c.source;
    if (c.status != 'applied' ||
        shown == null ||
        ['appId', 'resourceId', 'revision'].any((k) => shown[k] != source[k])) {
      continue;
    }
    final ids = presenting
        ? (c.intent!['targetIds'] ?? c.intent!['highlightIds']) as List?
        : c.highlightIds;
    return {
      'sectionId': presenting ? ids?.firstOrNull : c.sectionId,
      'highlightIds': ids ?? [],
      if (c.viewState != null) 'viewState': c.viewState,
    };
  }
  return null;
}

class ConversationMessages extends StatelessWidget {
  const ConversationMessages({
    super.key,
    required this.workspace,
    required this.controller,
    required this.onSelected,
  });
  final Workspace workspace;
  final ScrollController controller;
  final VoidCallback onSelected;
  Future<void> link(
    String href,
    List<Json> sources,
    List<ViewCommand> commands,
  ) async {
    try {
      final source = citedSource(href, sources);
      if (source != null) {
        await workspace.openSource(
          source,
          focus: sourceFocus(source, commands),
        );
      } else {
        final url = Uri.tryParse(href);
        if (url != null && ['http', 'https', 'mailto'].contains(url.scheme)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        }
      }
    } catch (e) {
      workspace.error = e.toString();
      workspace.changed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = workspace.snapshot;
    if (snapshot == null) return _welcome(context);
    final forwards = snapshot.forwards;
    if (snapshot.messages.isEmpty &&
        forwards.isEmpty &&
        snapshot.checkpoint == null) {
      return _welcome(context);
    }
    final turns = responseTurns(snapshot);
    final known = responseSources(snapshot.tools);
    final list = ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 12),
      itemCount: turns.length + 1,
      itemBuilder: (context, index) {
        if (index == turns.length) {
          return Column(
            children: [
              ...forwards.map(
                (forward) => ListTile(
                  title: Text('Forwarded: ${forward['sourceTitle']}'),
                  subtitle: Text(
                    '${(forward['messageIds'] as List).length} recorded messages\n${forward['note'] ?? ''}',
                  ),
                  onTap: () async {
                    try {
                      await workspace.selectConversation(
                        forward['sourceConversationId'] as String,
                      );
                      onSelected();
                    } catch (e) {
                      workspace.error = e.toString();
                      workspace.changed();
                    }
                  },
                ),
              ),
              if (snapshot.checkpoint != null)
                ExpansionTile(
                  title: const Text('Task checkpoint'),
                  children: [
                    SelectableText(snapshot.checkpoint!['content'] as String),
                  ],
                ),
            ],
          );
        }
        final turn = turns[turns.length - 1 - index];
        final tools = turn.tools, commands = turn.commands;
        final sources = responseSources(tools);
        final citations = [
          ...sources,
          ...known.where(
            (k) => !sources.any(
              (s) =>
                  s['appId'] == k['appId'] &&
                  s['resourceId'] == k['resourceId'],
            ),
          ),
        ];
        final runs = turn.runs;
        final latestRun = runs.lastOrNull;
        return Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...turn.messages
                  .where((m) => m.role == 'user')
                  .map((m) => _message(context, m, citations, commands)),
              if (tools.isNotEmpty || commands.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    border: Border.all(color: line),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: ExpansionTile(
                    dense: true,
                    leading: Icon(
                      latestRun?.status == 'running'
                          ? Icons.more_horiz
                          : Icons.check_circle_outline,
                      size: 16,
                      color: accent,
                    ),
                    title: Text(
                      latestRun?.status == 'running'
                          ? 'Working in your apps'
                          : 'Activity',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: muted,
                      ),
                    ),
                    subtitle: tools.isEmpty
                        ? null
                        : Text(
                            '${tools.length} tool ${tools.length == 1 ? 'call' : 'calls'}',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                    children: [
                      ...tools.map(
                        (tool) => ExpansionTile(
                          dense: true,
                          title: Text(
                            '${tool.name} · ${tool.status ?? 'completed'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          children: [
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: canvas,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: SelectableText(
                                const JsonEncoder.withIndent('  ').convert({
                                  'input': tool.input,
                                  'progress': tool.progress,
                                  'result': tool.output,
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...commands.map(
                        (c) => ListTile(
                          dense: true,
                          leading: Icon(
                            c.status == 'applied'
                                ? Icons.check_circle_outline
                                : Icons.info_outline,
                            size: 16,
                          ),
                          title: Text(
                            '${c.kind == 'present' ? 'App presentation' : 'View navigation'}: ${c.status}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          subtitle: c.error == null ? null : Text(c.error!),
                        ),
                      ),
                    ],
                  ),
                ),
              ...turn.messages
                  .where((m) => m.role != 'user')
                  .map((m) => _message(context, m, citations, commands)),
              if (sources.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'SOURCES',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                      color: muted,
                    ),
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: sources
                      .map(
                        (source) => Tooltip(
                          message: 'Open saved evidence',
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 260),
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: muted,
                                side: const BorderSide(color: line),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(7),
                                ),
                              ),
                              icon: const Icon(
                                Icons.description_outlined,
                                size: 14,
                              ),
                              label: Text(
                                source['title'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                              onPressed: () => link(
                                source['sourceUrl'] as String,
                                citations,
                                commands,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 14),
              ],
              for (final r in runs.where(
                (r) =>
                    ['cancelled', 'interrupted', 'failed'].contains(r.status),
              ))
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: r.status == 'failed'
                        ? const Color(0xfffff1ed)
                        : canvas,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(switch (r.status) {
                    'cancelled' => 'Response stopped',
                    'interrupted' =>
                      'Response interrupted. Send a message to continue.',
                    _ => 'Could not finish: ${r.error ?? 'Unknown error'}',
                  }, style: Theme.of(context).textTheme.bodySmall),
                ),
              const SizedBox(height: 12),
              const Divider(),
            ],
          ),
        );
      },
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: list),
        AnimatedBuilder(
          animation: controller,
          builder: (context, _) =>
              controller.positions.length == 1 && controller.offset > 200
              ? Positioned(
                  bottom: 8,
                  right: 16,
                  child: FilledButton.tonalIcon(
                    onPressed: () => controller.animateTo(
                      0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    ),
                    icon: const Icon(Icons.arrow_downward, size: 14),
                    label: const Text('Latest answer'),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _welcome(BuildContext context) => LayoutBuilder(
    builder: (context, size) => SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: size.maxHeight > 360 ? 50 : 8),
          const RelayMark(size: 36),
          const SizedBox(height: 22),
          const Text(
            'Let’s work on it.',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -.6,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Ask about what you’re viewing, compare information across apps, or pick up an earlier conversation.',
            style: TextStyle(fontSize: 14, height: 1.7, color: muted),
          ),
          const SizedBox(height: 26),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: canvas,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: line),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.layers_outlined, size: 18, color: accent),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Open an app to give Relay context. Your conversation stays with you as you switch tabs.',
                    style: TextStyle(fontSize: 12, height: 1.6, color: muted),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _message(
    BuildContext context,
    ChatMessage m,
    List<Json> citations,
    List<ViewCommand> commands,
  ) {
    final user = m.role == 'user';
    final created = DateTime.tryParse(m.createdAt ?? '')?.toLocal();
    final time = created == null
        ? ''
        : TimeOfDay.fromDateTime(created).format(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!user) ...[
                const RelayMark(size: 20),
                const SizedBox(width: 7),
              ],
              if (user) const Spacer(),
              Text(
                user ? 'You' : 'Relay',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
              ),
              if (time.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(time, style: const TextStyle(fontSize: 10, color: muted)),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (user)
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                margin: const EdgeInsets.only(left: 22),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  m.text,
                  style: const TextStyle(fontSize: 14, height: 1.6, color: ink),
                ),
              ),
            )
          else
            MarkdownBody(
              data: m.text,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 14,
                  height: 1.65,
                  color: ink,
                ),
                h1: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 22,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
                h2: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 18,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
                h3: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
                h1Padding: const EdgeInsets.only(top: 8, bottom: 8),
                h2Padding: const EdgeInsets.only(top: 8, bottom: 6),
                h3Padding: const EdgeInsets.only(top: 6, bottom: 4),
                blockSpacing: 12,
                listIndent: 20,
                listBullet: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 14,
                  color: muted,
                ),
                tableHead: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ink,
                ),
                tableBody: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 12,
                  color: ink,
                ),
                tableBorder: TableBorder.all(color: line),
                tableCellsPadding: const EdgeInsets.all(8),
                a: const TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  color: accent,
                  decoration: TextDecoration.underline,
                ),
                code: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: ink,
                  backgroundColor: canvas,
                ),
                codeblockDecoration: BoxDecoration(
                  color: canvas,
                  borderRadius: BorderRadius.circular(8),
                ),
                blockquoteDecoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: accent, width: 2)),
                ),
                blockquotePadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              builders: {
                'code': SourceCodeBuilder(
                  citations,
                  (source) =>
                      link(source['sourceUrl'] as String, [source], commands),
                ),
              },
              imageBuilder: (uri, title, alt) => Text(alt ?? ''),
              onTapLink: (_, href, _) {
                if (href != null) link(href, citations, commands);
              },
            ),
          if (m.hasCapture)
            const Text('Screenshot attached', style: TextStyle(fontSize: 12)),
          if (m.context?['source'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                'From ${m.context!['source']['title']}',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 11, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

class SavedReport extends StatelessWidget {
  const SavedReport({super.key, required this.report, this.error});
  final Json report;
  final String? error;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        report['source']['title'] as String,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      if (error != null)
        Text(
          'The saved evidence is available. Its app view could not open: $error',
        ),
      ...(report['sections'] as List).cast<Json>().map(
        (s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                s['title'] as String,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SelectableText(s['text'] as String),
            ],
          ),
        ),
      ),
    ],
  );
}

class SourceCodeBuilder extends MarkdownElementBuilder {
  SourceCodeBuilder(this.sources, this.open);
  final List<Json> sources;
  final Future<void> Function(Json) open;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.textContent.contains('\n')) return null;
    final source = citedSource(element.textContent, sources);
    if (source == null) return null;
    return InkWell(
      onTap: () => open(source),
      child: Text(
        element.textContent,
        style: preferredStyle?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
