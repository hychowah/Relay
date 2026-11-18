import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { HTTPException } from "hono/http-exception";
import type { ProviderMode, ProviderSettings, ProviderUpdate } from "../shared/types.ts";
import { defaultModels, isProviderMode, liveProviders, providerNames, reasoningEfforts, supportsReasoningEffort } from "../shared/provider.ts";

const alternatives = new Intl.ListFormat("en-GB", { type: "disjunction" });

type Connection = Omit<ProviderUpdate, "mode">;

export class ProviderSettingsStore {
  private file: string;
  private mode: ProviderMode;
  private connections: Partial<Record<ProviderMode, Connection>> = {};
  private env: NodeJS.ProcessEnv;

  constructor(dataDir: string, env: NodeJS.ProcessEnv = process.env) {
    mkdirSync(dataDir, { recursive: true });
    this.file = join(dataDir, "provider.json");
    this.env = env;
    const mode = env.RELAY_PROVIDER || "fixture";
    if (!isProviderMode(mode))
      throw new Error(`RELAY_PROVIDER must be ${alternatives.format(Object.keys(providerNames))}.`);
    this.mode = mode;
    if (existsSync(this.file)) {
      const saved = JSON.parse(readFileSync(this.file, "utf8"));
      this.mode = saved.mode;
      if (saved.connections) this.connections = saved.connections;
      else {
        // The original single-provider file retained a DeepSeek key even in demo mode.
        const { mode: previous, apiKey, ...connection } = saved;
        this.connections[previous as ProviderMode] = connection;
        if (apiKey) this.connections.deepseek = {
          model: this.defaultModel("deepseek"), ...this.connections.deepseek, apiKey,
        };
      }
      chmodSync(this.file, 0o600);
    }
  }

  private defaultModel(mode: ProviderMode): string {
    return this.env[(mode === "fixture" ? "DEEPSEEK" : liveProviders[mode].envPrefix) + "_MODEL"] || defaultModels[mode];
  }

  private connection(mode: ProviderMode): Connection {
    return this.connections[mode] ?? { model: this.defaultModel(mode) };
  }

  private keyEnvironment(mode: ProviderMode) {
    if (mode === "fixture") return {};
    const prefix = liveProviders[mode].envPrefix;
    return { key: this.env[prefix + "_API_KEY"]?.trim(), file: this.env[prefix + "_API_KEY_FILE"] };
  }

  configuration(settings: ProviderUpdate = {mode: this.mode, ...this.connection(this.mode)}): ProviderUpdate {
    const { key, file } = this.keyEnvironment(settings.mode);
    const apiKey = settings.mode === "fixture" ? undefined : settings.apiKey ||
      this.connections[settings.mode]?.apiKey || (file ? readFileSync(file, "utf8").trim() : key);
    return { ...settings, apiKey };
  }

  status(mode: ProviderMode = this.mode): ProviderSettings {
    const connection = this.connection(mode);
    const { key, file } = this.keyEnvironment(mode);
    return {
      mode, model: connection.model,
      ...(connection.reasoningEffort ? {reasoningEffort: connection.reasoningEffort} : {}),
      hasKey: mode !== "fixture" && Boolean(connection.apiKey || key || (file && existsSync(file))),
    };
  }

  prepare(input: ProviderUpdate): ProviderUpdate {
    if (!input || !isProviderMode(input.mode))
      throw new HTTPException(400, {message: `Choose ${alternatives.format([
        ...Object.values(liveProviders).map(provider => provider.name).sort(), "scripted demo",
      ])}.`});
    if (typeof input.model !== "string" || !input.model.trim())
      throw new HTTPException(400, {message: "Enter a model name."});
    if (input.apiKey !== undefined && typeof input.apiKey !== "string")
      throw new HTTPException(400, {message: "Enter an API key as text."});
    if (input.reasoningEffort !== undefined && !reasoningEfforts.includes(input.reasoningEffort))
      throw new HTTPException(400, {message: "Choose a supported thinking effort."});
    const effortSupported = supportsReasoningEffort(input.mode, input.model);
    if (input.reasoningEffort && input.reasoningEffort !== "default" && !effortSupported) {
      const models = Object.values(liveProviders).flatMap(provider => provider.effortModels);
      throw new HTTPException(400, {message: `Thinking effort is supported for ${new Intl.ListFormat("en-GB").format(models)}.`});
    }
    const previous = this.connections[input.mode] ?? (input.mode === "fixture" ? this.connection(this.mode) : undefined);
    const reasoningEffort = input.reasoningEffort ?? (effortSupported ? previous?.reasoningEffort : undefined);
    const next: ProviderUpdate = {
      mode: input.mode, model: input.model.trim(),
      ...(input.mode !== "fixture" ? {apiKey: input.apiKey?.trim() || this.connections[input.mode]?.apiKey} : {}),
      ...(reasoningEffort ? {reasoningEffort} : {}),
    };
    if (next.mode !== "fixture" && !this.configuration(next).apiKey)
      throw new HTTPException(400, {message: `Enter a ${providerNames[next.mode]} API key before enabling ${providerNames[next.mode]}.`});
    return next;
  }

  save(settings: ProviderUpdate) {
    const {mode, ...connection} = settings;
    const connections = {...this.connections, [mode]: connection};
    const temporary = this.file + ".tmp";
    writeFileSync(temporary, JSON.stringify({mode, connections}) + "\n", {mode: 0o600});
    chmodSync(temporary, 0o600);
    renameSync(temporary, this.file);
    this.connections = connections;
    this.mode = mode;
  }
}
