import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { flutterReleases } from '../server/flutter-releases.ts';
import { createWorkspace } from '../server/app.ts';
import { Store } from '../server/store.ts';

test('Flutter release delivery serves the fresh manifest and completed Mac archives only', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'relay-flutter-releases-'));
  const service = flutterReleases(directory);
  const file = 'Relay-Flutter-0.0.3-macOS-arm64.zip';
  const manifest = {version: '0.0.3', file};
  try {
    await writeFile(join(directory, 'latest.json'), JSON.stringify(manifest));
    await writeFile(join(directory, file), 'synthetic Flutter archive');
    const response = await service.request('/flutter-updates/latest.json');
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), manifest);
    const archive = await service.request('/flutter-updates/' + file);
    assert.equal(archive.status, 200);
    assert.equal(await archive.text(), 'synthetic Flutter archive');

    for (const name of ['search', 'tabs']) await writeFile(join(directory, `preview-${name}.json`), JSON.stringify({name}));
    assert.deepEqual(await (await service.request('/flutter-updates/previews.json')).json(), [{name: 'search'}, {name: 'tabs'}]);
    const pinned = 'Relay-Flutter-preview-' + 'a'.repeat(64) + '.zip';
    await writeFile(join(directory, pinned), 'pinned fixture');
    assert.equal(await (await service.request('/flutter-updates/' + pinned)).text(), 'pinned fixture');

    for (const name of ['provider.json', '.upload-pending']) {
      await writeFile(join(directory, name), 'private fixture');
      assert.equal((await service.request('/flutter-updates/' + name)).status, 404);
    }
    assert.equal((await service.request('/flutter-updates/%2e%2e%2fprovider.json')).status, 404);
  } finally {await rm(directory, {recursive: true, force: true});}
});

test('Flutter restart waits for work in its device and tab across conversations', async () => {
  const store = new Store(':memory:');
  const workspace = createWorkspace(store, () => [], {mode: 'fixture', model: 'fixture', configured: true});
  const first = store.createConversation('First', 'session-first');
  const second = store.createConversation('Second', 'session-second');
  const own = store.startRun(first.id, 'Synthetic task', 'mac', 'window');
  const other = store.startRun(second.id, 'Other task', 'phone', 'window');
  const busy = async (device: string, tab: string) => (await workspace.app.request(`/api/desktop/busy?deviceId=${device}&tabId=${tab}`)).json();
  try {
    assert.deepEqual(await busy('mac', 'window'), {busy: true});
    assert.deepEqual(await busy('mac', 'another-window'), {busy: false});
    store.finishRun(own.id, 'completed');
    assert.deepEqual(await busy('mac', 'window'), {busy: false});
    assert.deepEqual(await busy('phone', 'window'), {busy: true});
  } finally {
    store.finishRun(other.id, 'completed');
    await workspace.close(); store.close();
  }
});
