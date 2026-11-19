import { serve } from "@hono/node-server";
import { serveStatic } from "@hono/node-server/serve-static";
import { resolve } from "node:path";
import { startWorkspace } from "./runtime.ts";
import { appRegistry } from "./app-registry.ts";

const dataDir = resolve(process.env.RELAY_DATA_DIR ?? "runtime");
const apps = appRegistry(process.env.RELAY_APPS_FILE);
const workspace = await startWorkspace(dataDir, apps);
workspace.app.use("/*", serveStatic({ root: "./dist" }));
workspace.app.get("/", serveStatic({ path: "./dist/index.html" }));
const host = process.env.RELAY_HOST ?? "127.0.0.1";
const port = Number(process.env.PORT ?? 3210);
const server = serve(
  { fetch: workspace.app.fetch, hostname: host, port },
  () => {
    console.log(`Relay: http://${host}:${port}`);
  },
);

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  server.close();
  await workspace.close();
}
process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
