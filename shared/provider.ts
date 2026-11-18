// Public provider metadata. Credentials are resolved only by the service.
export const liveProviders = {
  deepseek: {
    name: "DeepSeek", defaultModel: "deepseek-flash",
    effortModels: ["deepseek-flash", "deepseek-v4-pro"],
    limit: { context: 1048576, output: 8192 },
    envPrefix: "DEEPSEEK", package: "@opencode/ai/providers/deepseek",
    baseURL: "https://api.deepseek.com/v1",
    auth: { header: "authorization", prefix: "Bearer " },
    models: { headers: undefined, paginated: false },
  },
  anthropic: {
    name: "Claude", defaultModel: "claude-sonnet-5-5",
    effortModels: [] as string[],
    limit: { context: 200000, output: 8192 },
    envPrefix: "ANTHROPIC", package: "@opencode/ai/providers/anthropic",
    baseURL: "https://api.anthropic.com/v1",
    auth: { header: "x-api-key", prefix: "" },
    models: { headers: { "anthropic-version": "2023-06-01" }, paginated: true },
  },
};

const providers = { fixture: { name: "Demo", defaultModel: "deepseek-flash" }, ...liveProviders };
export type ProviderMode = keyof typeof providers;
export const providerNames = Object.fromEntries(Object.entries(providers).map(([mode, provider]) => [mode, provider.name])) as Record<ProviderMode, string>;
export const defaultModels = Object.fromEntries(Object.entries(providers).map(([mode, provider]) => [mode, provider.defaultModel])) as Record<ProviderMode, string>;

export const reasoningEfforts = ["default", "none", "low", "high", "max"] as const;
export type ReasoningEffort = typeof reasoningEfforts[number];

export function supportsImageInput(mode: ProviderMode): boolean {
  return mode === "anthropic";
}

export function supportsReasoningEffort(mode: ProviderMode, model: string): boolean {
  // The fixture exercises the DeepSeek effort wire format with any model name.
  return mode === "fixture" || liveProviders[mode].effortModels.includes(model.trim());
}

export function isProviderMode(value: unknown): value is ProviderMode {
  return typeof value === "string" && Object.hasOwn(providers, value);
}
