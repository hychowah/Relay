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
    final colors = Theme.of(context).colorScheme;
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
                    border: Border.all(color: colors.outline),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: ExpansionTile(
                    dense: true,
                    leading: Icon(
                      latestRun?.status == 'running'
                          ? Icons.more_horiz
                          : Icons.check_circle_outline,
                      size: 16,
                      color: colors.primary,
                    ),
                    title: Text(
                      latestRun?.status == 'running'
                          ? 'Working in your apps'
                          : 'Activity',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    subtitle: tools.isEmpty
                        ? null
                        : Text(
                            '${tools.length} tool ${tools.length == 1 ? 'call' : 'calls'}',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
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
                                color: colors.surfaceContainerHighest,
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'SOURCES',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurfaceVariant,
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
                                foregroundColor: colors.onSurfaceVariant,
                                side: BorderSide(color: colors.outline),
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
                        ? colors.errorContainer
                        : colors.surfaceContainerHighest,
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

  Widget _welcome(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
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
            Text(
              'Ask about what you’re viewing, compare information across apps, or pick up an earlier conversation.',
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 26),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: colors.outline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.layers_outlined, size: 18, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Open an app to give Relay context. Your conversation stays with you as you switch tabs.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: colors.onSurfaceVariant,
                      ),
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

  Widget _message(
    BuildContext context,
    ChatMessage m,
    List<Json> citations,
    List<ViewCommand> commands,
  ) {
    final colors = Theme.of(context).colorScheme;
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
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              if (time.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (m.hasCapture)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(left: 22, bottom: 6),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: switch ((workspace.conversationId, m.id)) {
                      (final conversation?, final message?) => Image.network(
                        workspace.api
                            .captureUrl(conversation, message)
                            .toString(),
                        semanticLabel: 'Attached screenshot',
                        // Messages sent before screenshots were saved have none.
                        errorBuilder: (_, _, _) => const _CaptureNote(),
                      ),
                      _ => const _CaptureNote(),
                    },
                  ),
                ),
              ),
            ),
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
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  m.text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: colors.onSurface,
                  ),
                ),
              ),
            )
          else
            MarkdownBody(
              data: m.text,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 14,
                  height: 1.65,
                  color: colors.onSurface,
                ),
                h1: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 22,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
                h2: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 18,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
                h3: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
                h1Padding: const EdgeInsets.only(top: 8, bottom: 8),
                h2Padding: const EdgeInsets.only(top: 8, bottom: 6),
                h3Padding: const EdgeInsets.only(top: 6, bottom: 4),
                // The package fills unset styles from Flutter's default light
                // theme, not this app's, so text it shows needs a colour here.
                h4: TextStyle(color: colors.onSurface),
                h5: TextStyle(color: colors.onSurface),
                h6: TextStyle(color: colors.onSurface),
                blockquote: TextStyle(color: colors.onSurface),
                checkbox: TextStyle(color: colors.primary),
                horizontalRuleDecoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(width: 5, color: colors.outline),
                  ),
                ),
                blockSpacing: 12,
                listIndent: 20,
                listBullet: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 14,
                  color: colors.onSurfaceVariant,
                ),
                tableHead: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
                tableBody: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  fontSize: 12,
                  color: colors.onSurface,
                ),
                tableBorder: TableBorder.all(color: colors.outline),
                tableCellsPadding: const EdgeInsets.all(8),
                a: TextStyle(
                  fontFamily: '.AppleSystemUIFont',
                  color: colors.primary,
                  decoration: TextDecoration.underline,
                ),
                code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: colors.onSurface,
                  backgroundColor: colors.surfaceContainerHighest,
                ),
                codeblockDecoration: BoxDecoration(
                  color: colors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                blockquoteDecoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: colors.primary, width: 2),
                  ),
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
          if (m.context?['source'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(
                'From ${m.context!['source']['title']}',
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

class _CaptureNote extends StatelessWidget {
  const _CaptureNote();
  @override
  Widget build(BuildContext context) => Text(
    'Screenshot attached',
    style: TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
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
