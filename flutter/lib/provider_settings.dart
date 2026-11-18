import 'package:material_ui/material_ui.dart';

import 'relay_api.dart';
import 'workspace.dart';

const providerNames = {
  'deepseek': 'DeepSeek',
  'anthropic': 'Claude',
  'fixture': 'Demo',
};
const effortNames = {
  'default': 'Provider default',
  'none': 'None',
  'low': 'Low',
  'high': 'High',
  'max': 'Maximum',
};

class ProviderSettings extends StatefulWidget {
  const ProviderSettings({super.key, required this.workspace});
  final Workspace workspace;
  @override
  State<ProviderSettings> createState() => _ProviderSettingsState();
}

class _ProviderSettingsState extends State<ProviderSettings> {
  final keyInput = TextEditingController();
  Json? settings;
  List<Json> models = [];
  bool loading = true, saving = false;
  String? error;
  int request = 0;
  RelayApi get api => widget.workspace.api;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    keyInput.clear();
    keyInput.dispose();
    super.dispose();
  }

  Future<void> load([String? mode]) async {
    final current = ++request;
    setState(() {
      loading = true;
      error = null;
      models = [];
      keyInput.clear();
    });
    try {
      final next = await api.providerSettings(mode);
      if (!mounted || current != request) return;
      setState(() => settings = next);
      if (next['hasKey'] == true || next['mode'] == 'fixture') {
        await loadModels();
      }
    } catch (e) {
      if (mounted && current == request) setState(() => error = e.toString());
    } finally {
      if (mounted && current == request) setState(() => loading = false);
    }
  }

  Future<void> loadModels() async {
    final current = ++request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await api.providerModels({
        'mode': settings!['mode'],
        if (keyInput.text.trim().isNotEmpty) 'apiKey': keyInput.text.trim(),
      });
      if (!mounted || current != request) return;
      setState(() {
        models = result;
        if (!models.any((m) => m['id'] == settings!['model'])) {
          settings!['model'] = models.firstOrNull?['id'];
        }
      });
    } catch (e) {
      if (mounted && current == request) setState(() => error = e.toString());
    } finally {
      if (mounted && current == request) setState(() => loading = false);
    }
  }

  bool get effort =>
      models
          .where((m) => m['id'] == settings?['model'])
          .firstOrNull?['supportsReasoningEffort'] ==
      true;
  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await api.saveProvider({
        'mode': settings!['mode'],
        'model': settings!['model'],
        'reasoningEffort': effort
            ? settings!['reasoningEffort'] ?? 'default'
            : 'default',
        if (keyInput.text.trim().isNotEmpty) 'apiKey': keyInput.text.trim(),
      });
      keyInput.clear();
      await widget.workspace.loadConfig();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Provider and model'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            if (loading || saving) const LinearProgressIndicator(),
            if (settings != null) ...[
              DropdownButtonFormField<String>(
                initialValue: settings!['mode'] as String,
                decoration: const InputDecoration(labelText: 'Provider'),
                items: providerNames.entries
                    .map(
                      (e) =>
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                    )
                    .toList(),
                onChanged: saving || loading ? null : (value) => load(value),
              ),
              if (settings!['mode'] != 'fixture')
                TextField(
                  controller: keyInput,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: settings!['hasKey'] == true
                        ? 'Replace API key (optional)'
                        : 'API key',
                    helperText: 'Stored only by the WSL service.',
                  ),
                  onChanged: (_) => setState(() {
                    request++;
                    loading = false;
                    models = [];
                  }),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: loading || saving ? null : loadModels,
                  child: const Text('Load available models'),
                ),
              ),
              if (models.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey('${settings!['mode']}:${settings!['model']}'),
                  initialValue: settings!['model'] as String?,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Model'),
                  items: models
                      .map(
                        (m) => DropdownMenuItem(
                          value: m['id'] as String,
                          child: Text(
                            m['name'] as String,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: saving
                      ? null
                      : (value) => setState(() {
                          settings!['model'] = value;
                          settings!['reasoningEffort'] = 'default';
                        }),
                ),
              if (effort)
                DropdownButtonFormField<String>(
                  initialValue:
                      settings!['reasoningEffort'] as String? ?? 'default',
                  decoration: const InputDecoration(
                    labelText: 'Default thinking effort',
                  ),
                  items: effortNames.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: saving
                      ? null
                      : (value) => setState(
                          () => settings!['reasoningEffort'] = value,
                        ),
                ),
            ],
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: loading || saving || models.isEmpty || widget.workspace.busy
            ? null
            : save,
        child: const Text('Save'),
      ),
    ],
  );
}
