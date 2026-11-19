import type { AppView, Operation, OperationProgress, OperationResult, Report, Resource, Source } from "../../shared/types.ts";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { RegisteredApp } from "../app.ts";

export interface AppRegistration {
  id: string;
  name: string;
  serverUrl: string;
  browserUrl?: string;
  trustedNative?: boolean;
}

export interface Manifest {
  version: 1 | 2;
  id: string;
  name: string;
  description: string;
  instructions?: string;
  capabilities?: Record<string, boolean>;
  view: { path: string; resourceId?: string };
}

function origin(value: string): URL {
  const url = new URL(value);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password ||
    url.search || url.hash || url.pathname !== "/")
    throw new Error("App addresses must be HTTP(S) origins without credentials or paths.");
  return url;
}

export class AppRequestError extends Error {
  readonly status: ContentfulStatusCode;
  readonly kind: "unavailable" | "protocol" | "app";
  constructor(message: string, status: number, kind: "unavailable" | "protocol" | "app" = "unavailable") {
    super(message);
    this.status = status as ContentfulStatusCode;
    this.kind = kind;
  }
}

const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const protocol = (message: string): never => { throw new AppRequestError(message, 502, "protocol"); };

export class HttpIntegration {
  readonly server: URL;
  readonly browser: URL;
  private registration: AppRegistration;
  private contract?: Manifest;
  private readonly timeoutMs: number;

  constructor(registration: AppRegistration, timeoutMs = 10_000) {
    this.registration = registration;
    this.server = origin(registration.serverUrl);
    this.browser = origin(registration.browserUrl ?? registration.serverUrl);
    this.timeoutMs = timeoutMs;
  }

  static register(registration: AppRegistration): RegisteredApp {
    const integration = new HttpIntegration(registration);
    void integration.manifest().catch((error) => {
      console.warn(`${registration.name}: ${error instanceof Error ? error.message : "Manifest unavailable"}`);
    });
    return {
      id: registration.id, integration,
      get name() { return integration.contract?.name ?? registration.name; },
      get description() { return integration.contract?.description ?? "Configured app"; },
      get instructions() { return integration.contract?.instructions; },
      get resourceId() { return integration.contract?.view.resourceId; },
      get capabilities() { return integration.contract?.capabilities; },
      // Both clients choose the home view for v2. Let that first open retry an unknown manifest.
      get protocolVersion(): 2 | undefined { return integration.contract?.version === 1 ? undefined : 2; },
    };
  }

  private async request(path: string, init: RequestInit, timeout: AbortSignal, query?: Record<string, string>) {
    const url = new URL(path, this.server);
    if (query) url.search = new URLSearchParams(query).toString();
    let response: Response;
    try {
      response = await fetch(url, { ...init, redirect: "error",
        signal: init.signal ? AbortSignal.any([init.signal, timeout]) : timeout });
    } catch (error) {
      if (init.signal?.aborted) throw error;
      throw new AppRequestError(`${this.registration.name} is unavailable.`, 502);
    }
    if (!response.ok)
      throw new AppRequestError(`${this.registration.name} request failed (${response.status}).`, response.status, "app");
    return response;
  }

  private async get(path: string, query?: Record<string, string>, signal?: AbortSignal): Promise<any> {
    const response = await this.request(path, { signal }, AbortSignal.timeout(this.timeoutMs), query);
    try { return await response.json(); }
    catch (error) {
      if (signal?.aborted) throw error;
      if (error instanceof SyntaxError) return protocol("The app returned invalid JSON.");
      throw new AppRequestError(`${this.registration.name} response connection was lost.`, 502);
    }
  }

  async manifest(signal?: AbortSignal): Promise<Manifest> {
    if (this.contract) return this.contract;
    const manifest = await this.get("/_relay/manifest", undefined, signal);
    if (!object(manifest) || ![1, 2].includes(manifest.version as number) ||
      manifest.id !== this.registration.id || typeof manifest.name !== "string" ||
      typeof manifest.description !== "string" ||
      (manifest.instructions !== undefined && typeof manifest.instructions !== "string") ||
      (manifest.version === 1 && (!object(manifest.capabilities) || !manifest.capabilities.search || !manifest.capabilities.read)) ||
      !object(manifest.view) || manifest.view.path !== "/_relay/view" ||
      (manifest.view.resourceId !== undefined && (typeof manifest.view.resourceId !== "string" || !manifest.view.resourceId.trim())))
      return protocol("The app does not provide the expected Relay v1 or v2 interface.");
    this.contract = manifest as unknown as Manifest;
    return this.contract;
  }

  private source<T extends Resource>(source: T): T {
    if (!object(source) || source.appId !== this.registration.id ||
      typeof source.resourceId !== "string" || !source.resourceId ||
      typeof source.title !== "string" || !source.title || typeof source.sourceUrl !== "string" || !source.sourceUrl)
      return protocol("The app returned an invalid resource identity.");
    let url: URL;
    try { url = new URL(source.sourceUrl, this.browser); }
    catch { return protocol("The app returned an invalid source URL."); }
    if (url.origin === this.server.origin) {
      url.protocol = this.browser.protocol;
      url.host = this.browser.host;
      url.port = this.browser.port;
    }
    if (url.origin !== this.browser.origin || url.username || url.password)
      return protocol("The app returned a source outside its configured origin.");
    return { ...source, sourceUrl: url.href };
  }

  // Discovery is scoped by Relay to one allowed app. JSON Schema describes app-owned arguments.
  async discover(signal?: AbortSignal): Promise<{ instructions?: string; operations: Operation[] }> {
    const manifest = await this.manifest(signal);
    if (manifest.version !== 2) throw new AppRequestError("This app uses Relay v1 tools.", 400, "app");
    const body = await this.get("/_relay/operations", undefined, signal);
    if (!object(body) || !Array.isArray(body.operations)) return protocol("The app returned invalid operations.");
    const names = new Set<string>();
    for (const operation of body.operations) {
      if (!object(operation) || typeof operation.name !== "string" || !operation.name.trim() ||
        names.has(operation.name) || typeof operation.description !== "string" || !object(operation.inputSchema))
        return protocol("The app returned an invalid operation schema.");
      names.add(operation.name);
    }
    return { ...(manifest.instructions ? { instructions: manifest.instructions } : {}), operations: body.operations as Operation[] };
  }

  // Aborting disconnects this request; the app cooperatively decides whether remote work stops.
  async call(operation: string, args: Record<string, unknown>, options: {
    signal?: AbortSignal; onProgress?: (progress: OperationProgress) => void;
  } = {}): Promise<OperationResult> {
    const discovered = await this.discover(options.signal);
    if (!discovered.operations.some((entry) => entry.name === operation))
      throw new AppRequestError("The operation is not published by this app.", 400, "app");
    const deadline = new AbortController();
    const expire = () => deadline.abort();
    let timer = setTimeout(expire, this.timeoutMs);
    try {
      const response = await this.request("/_relay/call", {
        method: "POST", headers: { "Content-Type": "application/json", Accept: "application/x-ndjson" },
        body: JSON.stringify({ operation, arguments: args }), signal: options.signal,
      }, deadline.signal);
      clearTimeout(timer);
      timer = setTimeout(expire, this.timeoutMs * 6);
      return await this.readEvents(response, () => timer.refresh(), options.onProgress);
    } catch (error) {
      if (options.signal?.aborted) throw options.signal.reason;
      if (deadline.signal.aborted) throw new AppRequestError(`${this.registration.name} operation timed out.`, 502);
      if (error instanceof AppRequestError) throw error;
      throw new AppRequestError(`${this.registration.name} operation connection was lost.`, 502);
    } finally {
      clearTimeout(timer);
      deadline.abort();
    }
  }

  private async readEvents(
    response: Response, onEvent: () => void, onProgress?: (progress: OperationProgress) => void,
  ): Promise<OperationResult> {
    if (!response.headers.get("content-type")?.split(";")[0].includes("application/x-ndjson") || !response.body)
      return protocol("The app must return NDJSON operation events.");
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    let terminal: OperationResult | { error: string } | undefined;
    const event = (line: string) => {
      if (!line.trim()) return;
      let value: any;
      try { value = JSON.parse(line); } catch { return protocol("The app returned malformed NDJSON."); }
      if (!object(value) || terminal) return protocol("The app returned an invalid operation event sequence.");
      if (value.type === "progress" && typeof value.message === "string")
        onProgress?.({ type: "progress", message: value.message });
      else if (value.type === "error" && typeof value.message === "string") terminal = { error: value.message };
      else if (value.type === "result" && object(value.result) && "data" in value.result) {
        const result = value.result;
        if (result.sources !== undefined && !Array.isArray(result.sources)) return protocol("The app returned invalid result sources.");
        terminal = { data: result.data, ...(Array.isArray(result.sources) ? { sources: result.sources.map((item) => {
          const source = this.source(item as Source);
          if (typeof source.revision !== "string" || !source.revision) return protocol("The app returned invalid source revision.");
          return source;
        }) } : {}) };
      } else return protocol("The app returned an invalid operation event.");
      onEvent();
    };
    try {
      while (true) {
        const { done, value } = await reader.read();
        buffer += decoder.decode(value, { stream: !done });
        let end: number;
        while ((end = buffer.indexOf("\n")) >= 0) { event(buffer.slice(0, end)); buffer = buffer.slice(end + 1); }
        if (done) break;
      }
      if (buffer) event(buffer);
    } finally { reader.releaseLock(); }
    if (!terminal) return protocol("The app operation ended without a result.");
    if ("error" in terminal) throw new AppRequestError(terminal.error, 400, "app");
    return terminal;
  }

  async search(query: string): Promise<Resource[]> {
    if (!(await this.manifest()).capabilities?.search)
      throw new AppRequestError(`${this.registration.name} does not publish saved-evidence search. Use app_discover for its operations.`, 400, "app");
    const result = await this.get("/_relay/search", { q: query });
    if (!object(result) || !Array.isArray(result.resources)) return protocol("The app returned an invalid search result.");
    return result.resources.map((item: Resource) => this.source(item));
  }

  async read(resourceId: string, revision?: string): Promise<Report> {
    if (!(await this.manifest()).capabilities?.read)
      throw new AppRequestError(`${this.registration.name} does not publish saved evidence. Use app_discover for its operations.`, 400, "app");
    const result = await this.get("/_relay/read", { resourceId, ...(revision ? { revision } : {}) }).catch((error) => {
      if (error instanceof AppRequestError && error.status === 409)
        throw new AppRequestError("This saved version is no longer available in the live app. Its recorded evidence remains readable.", 409, error.kind);
      throw error;
    });
    if (!object(result)) return protocol("The app returned an invalid report.");
    const source = this.source(result.source as Source);
    if (source.resourceId !== resourceId || typeof source.revision !== "string" || !source.revision ||
      (revision && revision !== source.revision) || !Array.isArray(result.sections))
      return protocol("The app returned a different resource or revision.");
    return { source, sections: result.sections };
  }

  private browserView(token: string, parentOrigin: string, query: Record<string, string> = {}): AppView {
    const parent = origin(parentOrigin);
    if (parent.origin === this.browser.origin)
      throw new AppRequestError("Native app views must have a different origin from Relay.", 400, "app");
    const url = new URL("/_relay/view", this.browser);
    url.search = new URLSearchParams({ ...query, token, parentOrigin: parent.origin }).toString();
    // Native PDF viewers cannot run under an ancestor iframe sandbox. Only an
    // operator registration can opt out; app manifests cannot grant this trust.
    return { url: url.href, origin: this.browser.origin,
      ...(this.registration.trustedNative === true ? {} : {
        sandbox: "allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox",
      }), native: true };
  }

  async open(token: string, parentOrigin: string): Promise<AppView> {
    if ((await this.manifest()).version !== 2)
      throw new AppRequestError("This app requires a saved report view.", 400, "app");
    return this.browserView(token, parentOrigin);
  }

  async view(report: Report, token: string, parentOrigin: string): Promise<AppView> {
    const manifest = await this.manifest();
    const view = this.browserView(token, parentOrigin, { resourceId: report.source.resourceId, revision: report.source.revision,
      ...(manifest.version === 2 ? { protocol: "1" } : {}) });
    await this.read(report.source.resourceId, report.source.revision);
    return view;
  }
}
