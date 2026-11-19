import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import {
  HttpIntegration,
  AppRequestError,
} from "../server/integrations/http.ts";
import { createWorkspace } from "../server/app.ts";
import { Store } from "../server/store.ts";

async function nativeFixture() {
  const state = {
    manifest: {
      version: 1,
      id: "garden",
      name: "Garden ledger",
      description: "Seed inventory",
      instructions: "Search plant names, or leave the query empty.",
      capabilities: { search: true, read: true, navigate: true },
      view: { path: "/_relay/view", resourceId: "seed-ledger" },
    } as Record<string, unknown>,
    readMode: "exact" as "exact" | "mismatch" | "unavailable",
    sourceUrl: "/records/seed-ledger",
  };
  const requests: URL[] = [];
  const server = createServer((request, response) => {
    const url = new URL(request.url!, "http://fixture");
    requests.push(url);
    const json = (body: unknown, status = 200) =>
      response
        .writeHead(status, { "Content-Type": "application/json" })
        .end(JSON.stringify(body));
    const source = {
      appId: "garden",
      resourceId: "seed-ledger",
      title: "Seasonal seed ledger",
      sourceUrl: state.sourceUrl,
    };
    if (url.pathname === "/_relay/manifest") json(state.manifest);
    else if (url.pathname === "/_relay/search") json({ resources: [source] });
    else if (url.pathname === "/_relay/read") {
      if (state.readMode === "unavailable") {
        json({ error: "Publication no longer served" }, 409);
        return;
      }
      json({
        source: {
          ...source,
          revision:
            state.readMode === "mismatch"
              ? "newer-publication"
              : (url.searchParams.get("revision") ?? "publication-7"),
        },
        sections: [
          {
            id: "content",
            title: "Inventory",
            text: "Three trays of basil seeds.",
          },
        ],
      });
    } else json({ error: "Not found" }, 404);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    state,
    requests,
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections();
        server.close(() => resolve());
      }),
  };
}

test("native HTTP integration resolves browser sources and pins reads and views to the requested revision", async () => {
  const fixture = await nativeFixture();
  try {
    const adapter = new HttpIntegration({
      id: "garden",
      name: "Garden ledger",
      serverUrl: fixture.origin,
      browserUrl: "https://garden.test",
    });
    assert.equal(
      (await adapter.manifest()).instructions,
      "Search plant names, or leave the query empty.",
    );
    assert.equal((await adapter.manifest()).view.resourceId, "seed-ledger");
    const resources = await adapter.search("basil & mint");
    assert.equal(
      resources[0].sourceUrl,
      "https://garden.test/records/seed-ledger",
    );
    assert.equal(
      fixture.requests.at(-1)!.searchParams.get("q"),
      "basil & mint",
    );
    const report = await adapter.read("seed-ledger", "publication-3");
    assert.equal(report.source.revision, "publication-3");
    assert.equal(
      fixture.requests.at(-1)!.searchParams.get("revision"),
      "publication-3",
    );
    const view = await adapter.view(report, "view-token", "https://relay.test");
    const url = new URL(view.url);
    assert.equal(view.native, true);
    assert.equal(view.origin, "https://garden.test");
    assert.equal(
      view.sandbox,
      "allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox",
    );
    assert.equal(url.pathname, "/_relay/view");
    assert.equal(url.searchParams.get("revision"), "publication-3");
    assert.equal(url.searchParams.get("resourceId"), "seed-ledger");
    assert.equal(url.searchParams.get("token"), "view-token");
    assert.equal(url.searchParams.get("parentOrigin"), "https://relay.test");
    const trusted = new HttpIntegration({
      id: "garden", name: "Garden ledger", serverUrl: fixture.origin,
      browserUrl: "https://garden.test", trustedNative: true,
    });
    const trustedView = await trusted.view(report, "view-token", "https://relay.test");
    assert.equal(trustedView.native, true);
    assert.equal("sandbox" in trustedView, false);
    await assert.rejects(
      trusted.view(report, "token", "https://garden.test"),
      (error) => error instanceof AppRequestError && error.status === 400,
    );
    await assert.rejects(
      adapter.view(report, "token", "https://garden.test"),
      (error) => error instanceof AppRequestError && error.status === 400,
    );

    fixture.state.sourceUrl = `${fixture.origin}/records/seed-ledger`;
    assert.equal(
      (await adapter.search("")).at(0)!.sourceUrl,
      "https://garden.test/records/seed-ledger",
    );
    fixture.state.sourceUrl = "https://unconfigured.test/records/seed-ledger";
    await assert.rejects(adapter.search(""), /outside its configured origin/);
  } finally {
    await fixture.close();
  }
});

test("native HTTP integration rejects incompatible manifests and unavailable or silently changed revisions", async () => {
  const fixture = await nativeFixture();
  try {
    const adapter = new HttpIntegration({
      id: "garden",
      name: "Garden ledger",
      serverUrl: fixture.origin,
    });
    const valid = fixture.state.manifest;
    for (const patch of [
      { version: 3 },
      { id: "another-app" },
      { capabilities: { search: true } },
      { view: { path: "/arbitrary" } },
      { view: { path: "/_relay/view", resourceId: 7 } },
    ]) {
      fixture.state.manifest = { ...valid, ...patch };
      await assert.rejects(adapter.manifest(), /expected Relay v1 or v2 interface/);
    }
    fixture.state.manifest = valid;
    const report = await adapter.read("seed-ledger", "publication-3");
    fixture.state.readMode = "mismatch";
    await assert.rejects(
      adapter.read("seed-ledger", "publication-3"),
      /different resource or revision/,
    );
    await assert.rejects(
      adapter.view(report, "token", "https://relay.test"),
      /different resource or revision/,
    );
    fixture.state.readMode = "unavailable";
    await assert.rejects(
      adapter.view(report, "token", "https://relay.test"),
      (error) => error instanceof AppRequestError && error.status === 409,
    );
  } finally {
    await fixture.close();
  }
});

test("a fourth unrelated native app works through registration and generic workspace routes", async () => {
  const fixture = await nativeFixture();
  const store = new Store(":memory:");
  const adapter = new HttpIntegration({
    id: "garden",
    name: "Garden ledger",
    serverUrl: fixture.origin,
    browserUrl: "https://garden.test",
  });
  const apps = ["research", "backtests", "robotics", "garden"].map((id) => ({
    id,
    name: id,
    description: "Registered fixture",
    integration: adapter,
  }));
  const workspace = createWorkspace(store, () => apps, {
    mode: "fixture",
    model: "scripted",
    configured: true,
  });
  try {
    const config = await (await workspace.app.request("/api/config")).json();
    assert.deepEqual(
      config.apps.map((app: { id: string }) => app.id),
      ["research", "backtests", "robotics", "garden"],
    );
    const search = await workspace.app.request(
      "/api/apps/garden/search?q=basil",
    );
    assert.equal(search.status, 200);
    assert.equal((await search.json())[0].appId, "garden");
    const read = await workspace.app.request(
      "/api/apps/garden/read?resourceId=seed-ledger",
    );
    assert.equal(read.status, 200);
    const report = await read.json();
    assert.equal(report.source.revision, "publication-7");
    assert.equal(
      store.report("garden", "seed-ledger", "publication-7")!.sections[0].text,
      "Three trays of basil seeds.",
    );
    fixture.state.readMode = "unavailable";
    const unavailable = await workspace.app.request(
      "/api/apps/garden/view?resourceId=seed-ledger&revision=publication-7&token=view-token&parentOrigin=https%3A%2F%2Frelay.test",
    );
    assert.equal(unavailable.status, 409);
    assert.equal(
      (
        await workspace.app.request(
          "/api/apps/garden/report?resourceId=seed-ledger&revision=publication-7",
        )
      ).status,
      200,
      "Saved evidence remains available when its native view no longer serves that publication",
    );
    assert.equal(
      (await workspace.app.request("/api/apps/missing/search")).status,
      404,
    );
  } finally {
    await workspace.close();
    store.close();
    await fixture.close();
  }
});

test("v2 home views and saved v1 evidence use their respective browser bridges", async () => {
  const fixture = await nativeFixture();
  fixture.state.manifest.version = 2;
  const store = new Store(":memory:");
  const adapter = new HttpIntegration({ id: "garden", name: "Garden ledger", serverUrl: fixture.origin, browserUrl: "https://garden.test" });
  const workspace = createWorkspace(store, () => [{ id: "garden", name: "Garden", description: "Seeds", protocolVersion: 2, capabilities: { search: true }, integration: adapter }], {
    mode: "fixture", model: "scripted", configured: true,
  });
  try {
    const home = await workspace.app.request("/api/apps/garden/view?token=home&parentOrigin=https://relay.test");
    assert.equal(home.status, 200);
    const homeUrl = new URL((await home.json()).url);
    assert.equal(homeUrl.searchParams.get("resourceId"), null);
    assert.equal(homeUrl.searchParams.get("protocol"), null);
    assert.ok(!fixture.requests.some((url) => url.pathname === "/_relay/read"));
    const saved = await workspace.app.request("/api/apps/garden/view?resourceId=seed-ledger&revision=publication-7&token=saved&parentOrigin=https://relay.test");
    assert.equal(saved.status, 200);
    const savedUrl = new URL((await saved.json()).url);
    assert.equal(savedUrl.searchParams.get("protocol"), "1");
    assert.equal(savedUrl.searchParams.get("resourceId"), "seed-ledger");
    assert.equal(savedUrl.searchParams.get("revision"), "publication-7");
    assert.equal((await (await workspace.app.request("/api/config")).json()).apps[0].capabilities.search, true);
  } finally { await workspace.close(); store.close(); await fixture.close(); }
});
