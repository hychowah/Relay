import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Hono } from 'hono';
import { serveStatic } from '@hono/node-server/serve-static';

export function flutterReleases(directory: string) {
  const app = new Hono();
  const route = '/flutter-updates/';
  const archive = /^Relay-Flutter-\d+\.\d+\.\d+-macOS-arm64\.zip$/;
  app.get(route + 'previews.json', async c => {
    c.header('Cache-Control', 'no-store');
    let files: string[];
    try { files = await readdir(directory); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return c.json([]); throw error; }
    const manifests = files.filter(file => /^preview-[a-z0-9][a-z0-9-]{0,62}\.json$/.test(file)).sort();
    const previews = [];
    for (const file of manifests) {
      try { previews.push(JSON.parse(await readFile(join(directory, file), 'utf8'))); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
    }
    return c.json(previews);
  });
  app.use(`${route}:file`, async (c, next) => {
    const file = c.req.param('file') || '';
    const preview = /^Relay-Flutter-preview-[a-f0-9]{64}\.zip$/.test(file);
    if (file !== 'latest.json' && !archive.test(file) && !preview) return c.notFound();
    if (file === 'latest.json') c.header('Cache-Control', 'no-store');
    await next();
  });
  app.get(`${route}:file`, serveStatic({root: directory, rewriteRequestPath: path => path.replace(route, '/')}));
  return app;
}
