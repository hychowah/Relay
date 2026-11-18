import { HTTPException } from "hono/http-exception";
import type { ProviderModel, ProviderUpdate } from "../shared/types.ts";
import { defaultModels, liveProviders, providerNames } from "../shared/provider.ts";
import { ProviderNetworkError, requireNordVPN, createProviderRequest } from "./provider-network.ts";

// Discovery returns the provider's model IDs and labels, never a hard-coded list
// presented as account access. It neither saves credentials nor switches models.
export async function listProviderModels(
  connection: ProviderUpdate,
  signal?: AbortSignal,
  requireNetwork: () => Promise<void> = requireNordVPN,
): Promise<ProviderModel[]> {
  if (connection.mode === "fixture") return [{id: defaultModels.fixture, name: "Scripted demo"}];
  if (!connection.apiKey) throw new HTTPException(400, {message: "Enter an API key to load models."});
  const transport = liveProviders[connection.mode];
  const send = createProviderRequest(transport, connection.apiKey, requireNetwork);
  const endpoint = new URL(transport.baseURL + "/models");
  if (transport.models.paginated) endpoint.searchParams.set("limit", "100");
  const models = new Map<string, ProviderModel>();
  const cursors = new Set<string>();
  try {
    while (true) {
      const timeout = AbortSignal.timeout(15000);
      const response = await send(endpoint.pathname + endpoint.search, {
        headers: transport.models.headers,
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      });
      if (!response.ok) throw new HTTPException(response.status === 401 || response.status === 403 ? 400 : 502, {
        message: response.status === 401 || response.status === 403
          ? `${providerNames[connection.mode]} did not accept this key for model discovery. Check the key and its access.`
          : `${providerNames[connection.mode]} could not list models (${response.status}). Try again shortly.`,
      });
      const result = await response.json();
      if (!Array.isArray(result.data)) throw new Error("Invalid model list");
      for (const row of result.data) {
        if (!row || typeof row.id !== "string" || !row.id.trim()) throw new Error("Invalid model ID");
        if (row.lifecycle === "retired") continue;
        const name = row.display_name || row.name;
        models.set(row.id, {id: row.id, name: typeof name === "string" && name.trim() ? name : row.id});
      }
      if (!transport.models.paginated || !result.has_more) break;
      if (typeof result.last_id !== "string" || !result.last_id || cursors.has(result.last_id)) throw new Error("Invalid model cursor");
      cursors.add(result.last_id);
      endpoint.searchParams.set("after_id", result.last_id);
    }
    return [...models.values()];
  } catch (error) {
    if (error instanceof HTTPException) throw error;
    if (error instanceof ProviderNetworkError) throw new HTTPException(403, {message: error.message});
    throw new HTTPException(502, {message: `Could not load ${providerNames[connection.mode]} models. Check the connection and try again.`});
  }
}
