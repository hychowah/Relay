import { resolve } from "node:path";
import { Store } from "./store.ts";
import { createWorkspace, type RegisteredApp } from "./app.ts";
import { addBugReports } from "./bug-reports.ts";
import { addBrowserHistory, browserHistoryData } from "./browser-history.ts";
import { addHighlights, highlightsData } from "./highlights.ts";
import { addStoredData } from "./stored-data.ts";
import { startProviderGateway } from "./provider-gateway.ts";
import { liveProviders } from "../shared/provider.ts";
import { Harness } from "./harness.ts";
import { listProviderModels } from "./provider-models.ts";
import { ProviderSettingsStore } from "./provider-settings.ts";
import type { ProviderUpdate } from "../shared/types.ts";

export async function startWorkspace(dataDir: string, apps: () => RegisteredApp[]) {
  const settings = new ProviderSettingsStore(dataDir);
  let configuration = settings.configuration();
  const { mode, model, apiKey } = configuration;
  if (mode !== "fixture" && !apiKey)
    throw new Error(
      "Configure the selected provider API key before starting live mode.",
    );

  const store = new Store(resolve(dataDir, "relay.sqlite"));
  store.recover();
  const workspace = createWorkspace(
    store,
    apps,
    {
      mode,
      model: mode === "fixture" ? "Scripted local fixture" : model,
      configured: mode === "fixture" || Boolean(apiKey),
    },
    {
      get: (mode) => settings.status(mode), update: changeProvider,
      models: (input, signal) => listProviderModels(settings.configuration(settings.prepare({
        ...input, model: settings.status(input.mode).model,
      })), signal),
    },
  );
  addBugReports(workspace.app, resolve(dataDir, "bug-reports"), store);
  addBrowserHistory(workspace.app, store);
  addHighlights(workspace.app, store);
  const stored = addStoredData(workspace.app, store, [browserHistoryData(store), highlightsData(store)]);
  // A clean-up that fails must not stop the server or its start.
  const cleanStoredData = () => {
    try { stored(); }
    catch (error) { console.warn("Stored data clean-up failed.", error); }
  };
  cleanStoredData();
  const cleanTimer = setInterval(cleanStoredData, 60 * 60_000);
  cleanTimer.unref();

  async function startAgent({ mode, model, reasoningEffort, apiKey }: ProviderUpdate) {
    const gateway = mode === "fixture" ? undefined : await startProviderGateway(liveProviders[mode], apiKey!);
    try {
      const harness = await Harness.start({
        dataDir: resolve(dataDir, "harness"),
        mode, model, reasoningEffort,
        gateway: gateway && { url: gateway.url, token: gateway.token },
        apps,
        toolHandler: workspace.toolHandler,
        contextHandler: workspace.agentContext,
      });
      return {
        harness,
        async close() {
          try { await harness.close(); }
          finally { await gateway?.close(); }
        },
      };
    } catch (error) {
      await gateway?.close();
      throw error;
    }
  }

  let agent = await startAgent(configuration);
  workspace.setHarness(agent.harness);
  await workspace.purgeTrash();
  const trashTimer = setInterval(() => void workspace.purgeTrash(), 60_000);
  trashTimer.unref();

  async function changeProvider(input: ProviderUpdate) {
    const next = settings.prepare(input);
    const nextConfiguration = settings.configuration(next);
    const previous = configuration;
    await agent.close();
    try {
      const replacement = await startAgent(nextConfiguration);
      try {
        settings.save(next);
      } catch (error) {
        await replacement.close();
        throw error;
      }
      agent = replacement;
      configuration = nextConfiguration;
    } catch {
      try {
        agent = await startAgent(previous);
        workspace.setHarness(agent.harness);
      } catch {
        throw new Error(
          "The agent could not restart. Settings were not saved; restart Relay to retry.",
        );
      }
      throw new Error(
        "Provider settings could not be applied. Previous settings are still active.",
      );
    }
    workspace.setHarness(agent.harness);
    return settings.status();
  }

  return {
    ...workspace,
    async close() {
      clearInterval(trashTimer);
      clearInterval(cleanTimer);
      await workspace.close();
      await agent.close();
      store.close();
    },
  };
}
