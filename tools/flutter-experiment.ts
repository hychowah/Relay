// Backend for the Flutter app. The service sets RELAY_DATA_DIR; the default is this checkout's test data.
import {flutterReleases} from '../server/flutter-releases.ts';
import {serve} from '@hono/node-server';
import {serveStatic} from '@hono/node-server/serve-static';
import {mkdirSync, existsSync, copyFileSync, chmodSync} from 'node:fs';
import {appRegistry} from '../server/app-registry.ts';
import {startWorkspace} from '../server/runtime.ts';
import {createBrowser} from '../server/browser.ts';
import {ProviderSettingsStore} from '../server/provider-settings.ts';

const relayOrigin = process.env.FLUTTER_RELAY_ORIGIN || 'http://127.0.0.1:3250';
const browserOrigin = process.env.FLUTTER_BROWSER_ORIGIN || 'http://127.0.0.1:3251';
const broker = createBrowser();
const browser = serve({fetch:broker.app.fetch, hostname:'127.0.0.1', port:3251});
broker.attach(browser);
const apps = appRegistry(process.env.RELAY_APPS_FILE,
  [{id:'browser',name:'Browser',serverUrl:'http://127.0.0.1:3251',browserUrl:browserOrigin}]);
const dataDir = process.env.RELAY_DATA_DIR || 'runtime/flutter';
mkdirSync(dataDir, {recursive:true});
// Import service settings once; subsequent changes belong to this experiment.
if (process.env.RELAY_PROVIDER_DIR && !existsSync(`${dataDir}/provider.json`)) {
  const source = `${process.env.RELAY_PROVIDER_DIR}/provider.json`;
  if (existsSync(source)) {
    copyFileSync(source, `${dataDir}/provider.json`);
    chmodSync(`${dataDir}/provider.json`, 0o600);
  }
  const settings = new ProviderSettingsStore(dataDir);
  settings.save(settings.prepare({mode:'deepseek', model:settings.status('deepseek').model}));
}
const workspace = await startWorkspace(dataDir, apps);
workspace.app.route('/', flutterReleases(`${dataDir}/releases`));
workspace.app.use('/flutter-host.html', async (c, next) => {c.header('Cache-Control', 'no-store'); await next();});
workspace.app.use('/*', serveStatic({root:'./public'}));
const server = serve({fetch:workspace.app.fetch, hostname:'127.0.0.1', port:3250});
console.log(`Flutter experiment: ${relayOrigin}`);
async function close() {server.close();broker.close();browser.close();await workspace.close();}
process.once('SIGTERM',()=>void close());
process.once('SIGINT',()=>void close());
