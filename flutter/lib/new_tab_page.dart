import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace_style.dart';

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
          (app) =>
              app.hasView &&
              '${app.name} ${app.description}'.toLowerCase().contains(
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
