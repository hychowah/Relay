import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace.dart';

class AppLibrary extends StatefulWidget {
  const AppLibrary({super.key, required this.workspace, this.appId});
  final Workspace workspace;
  final String? appId;
  @override
  State<AppLibrary> createState() => _AppLibraryState();
}

class _AppLibraryState extends State<AppLibrary> {
  late String? selected =
      widget.appId ??
      widget.workspace.allowedApps.where((a) => a.canSearch).firstOrNull?.id;
  final query = TextEditingController();
  List<Json> resources = [];
  String? error;
  bool loading = false;
  int request = 0;
  Timer? debounce;
  @override
  void initState() {
    super.initState();
    search();
  }

  @override
  void dispose() {
    query.dispose();
    debounce?.cancel();
    super.dispose();
  }

  Future<void> search() async {
    if (selected == null) return;
    final current = ++request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.workspace.api.searchApp(
        selected!,
        query.text,
      );
      if (mounted && current == request) {
        setState(() => resources = result);
      }
    } catch (e) {
      if (mounted && current == request) setState(() => error = e.toString());
    } finally {
      if (mounted && current == request) setState(() => loading = false);
    }
  }

  Future<void> open(Json resource) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      await widget.workspace.openSource(resource);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 560,
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(child: Text('App library')),
                IconButton(
                  tooltip: 'Close library',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            DropdownButtonFormField<String>(
              initialValue: selected,
              decoration: const InputDecoration(labelText: 'App'),
              items: widget.workspace.allowedApps
                  .where((a) => a.canSearch)
                  .map(
                    (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                  )
                  .toList(),
              onChanged: (value) {
                selected = value;
                search();
              },
            ),
            TextField(
              controller: query,
              decoration: const InputDecoration(
                labelText: 'Search app documents',
              ),
              onSubmitted: (_) => search(),
              onChanged: (_) {
                debounce?.cancel();
                request++;
                debounce = Timer(const Duration(milliseconds: 250), search);
              },
            ),
            if (loading) const LinearProgressIndicator(),
            if (error != null) Text(error!),
            Expanded(
              child: resources.isEmpty && !loading
                  ? const Center(child: Text('No documents found'))
                  : ListView.builder(
                      itemCount: resources.length,
                      itemBuilder: (context, index) => ListTile(
                        title: Text(resources[index]['title'] as String),
                        onTap: loading ? null : () => open(resources[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
