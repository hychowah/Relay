import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { gunzipSync } from 'node:zlib';
import test from 'node:test';

// Stands in for the build Mac: the "SSH" wrapper runs each command here, with
// small programs in place of the Flutter and macOS tools.
const tools: Record<string, string> = {
  ssh: '#!/bin/bash\nexport PATH="$(dirname "$0"):$PATH"\nexec bash -c "$1"\n',
  codesign: '#!/bin/bash\n',
  flutter: `#!/usr/bin/env python3
import pathlib, plistlib, re, sys
info = plistlib.loads(pathlib.Path('macos/Runner/Info.plist').read_bytes())
name, number = re.search(r'^version: (.+)\\+(.+)$', pathlib.Path('pubspec.yaml').read_text(), re.M).groups()
for flag in sys.argv:
    if flag.startswith('--build-number='):
        number = flag.split('=')[1]
info.update(CFBundleIdentifier='app.relay.flutterExperiment', CFBundleShortVersionString=name, CFBundleVersion=number)
target = pathlib.Path('build/macos/Build/Products/Release/Relay Flutter.app/Contents')
target.mkdir(parents=True)
(target / 'Info.plist').write_bytes(plistlib.dumps(info))
(target / 'flags').write_text(' '.join(sys.argv))
(target / 'MacOS').mkdir()
(target / 'MacOS/Relay Flutter').write_text('engine')
(target / 'MacOS/Relay Flutter').chmod(0o755)
(target / 'Current').symlink_to('MacOS')
`,
  ditto: `#!/usr/bin/env python3
import os, pathlib, sys, zipfile
bundle, output = pathlib.Path(sys.argv[-2]), sys.argv[-1]
with zipfile.ZipFile(output, 'w') as package:
    for path in sorted(bundle.rglob('*')):
        name = str(path.relative_to(bundle.parent))
        if path.is_symlink():
            link = zipfile.ZipInfo(name)
            link.external_attr = 0o120755 << 16
            package.writestr(link, os.readlink(path))
        elif path.is_file():
            package.write(path, name)
`,
  shasum: `#!/usr/bin/env python3
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[-1]).read_bytes()).hexdigest(), sys.argv[-1])
`,
};

test('one tool publishes test builds and Stable with their stored files, and Stable retires the test builds it contains', t => {
  const root = mkdtempSync(join(tmpdir(), 'relay-publish-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const repo = join(root, 'repo');
  const releases = join(root, 'feed');
  const mac = join(root, 'mac');
  for (const directory of [join(repo, 'flutter/macos/Runner'), releases, mac]) mkdirSync(directory, {recursive: true});
  for (const [name, source] of Object.entries(tools)) writeFileSync(join(mac, name), source, {mode: 0o755});
  const options = {
    cwd: repo,
    env: {...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1'},
    encoding: 'utf8' as const,
  };
  const git = (...args: string[]) =>
    execFileSync('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', ...args], {...options, stdio: 'pipe'}).trim();
  const source = join(repo, 'flutter/lib.dart');
  const commit = (text: string) => {
    writeFileSync(source, text);
    git('add', '.');
    git('commit', '-m', text);
    return git('rev-parse', 'HEAD');
  };
  git('init', '-b', 'main');
  writeFileSync(join(repo, 'flutter/pubspec.yaml'), 'name: relay_flutter\nversion: 1.2.3+4\n');
  writeFileSync(join(repo, 'flutter/macos/Runner/Info.plist'),
    '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>RelayUpdateFormat</key><string>1</string></dict></plist>\n');
  commit('base');
  git('config', 'relay.flutterReleases', releases);
  git('config', 'relay.macSSH', join(mac, 'ssh'));
  git('config', 'relay.appUrl', 'http://relay.test');

  const publish = (argument: string) => spawnSync(resolve('tools/publish-flutter'), [argument], options);
  const feed = () => readdirSync(releases).filter(file => !file.startsWith('.')).sort();
  const listed = (file: string) => JSON.parse(readFileSync(join(releases, file), 'utf8'));
  const published = (argument: string) => {
    const result = publish(argument);
    assert.equal(result.status, 0, result.stderr);
  };
  const store = join(releases, 'files');
  const stored = (hash: string) => gunzipSync(readFileSync(join(store, hash + '.gz')));
  const sha256 = (data: Buffer) => createHash('sha256').update(data).digest('hex');
  // Each listed build's file list and every file it names, by content hash.
  const used = () => readdirSync(releases).filter(file => file === 'latest.json' || file.startsWith('preview-'))
    .flatMap(file => {
      const list = listed(file).fileList;
      return [list.sha256, ...JSON.parse(stored(list.sha256).toString()).filter((entry: {sha256?: string}) => entry.sha256)
        .map((entry: {sha256: string}) => entry.sha256)];
    });

  git('checkout', '-b', 'feature/search');
  const search = commit('search');
  published('search');
  assert.equal(listed('preview-search.json').commit, search);
  const fileList = listed('preview-search.json').fileList;
  const listing = stored(fileList.sha256);
  assert.equal(sha256(listing), fileList.sha256);
  const entries = JSON.parse(listing.toString());
  assert.deepEqual(entries.find((entry: {path: string}) => entry.path === 'Contents/Current'), {path: 'Contents/Current', link: 'MacOS'});
  const engine = entries.find((entry: {path: string}) => entry.path === 'Contents/MacOS/Relay Flutter');
  assert.equal(engine.exec, true);
  assert.equal(stored(engine.sha256).toString(), 'engine');
  assert.equal(entries.find((entry: {path: string}) => entry.path === 'Contents/Info.plist').exec, false);
  // Republishing a name keeps its earlier ZIP (see the Flutter plan's Next) but not its unused list.
  const earlier = listed('preview-search.json').file;
  published('search');
  assert.notEqual(listed('preview-search.json').fileList.sha256, fileList.sha256);
  assert.ok(!readdirSync(store).includes(fileList.sha256 + '.gz'));
  writeFileSync(source, 'uncommitted');
  published('draft');
  assert.equal(listed('preview-draft.json').dirty, true);
  git('checkout', '--', '.');
  git('checkout', '-b', 'feature/tabs', 'main');
  commit('tabs');
  published('tabs');

  writeFileSync(source, 'uncommitted');
  git('checkout', '--detach');
  const before = feed();
  assert.match(publish('detached').stderr, /Check out a branch/);
  assert.match(publish('--stable').stderr, /Commit the Flutter changes/);
  assert.deepEqual(feed(), before);

  git('checkout', '--', '.');
  git('checkout', 'main');
  git('merge', '--no-ff', '-m', 'merge search', 'feature/search');
  published('--stable');
  const stable = listed('latest.json');
  assert.deepEqual(
    {...stable, sha256: '', size: 0, fileList: undefined},
    {version: '1.2.3', file: 'Relay-Flutter-1.2.3-macOS-arm64.zip', size: 0, sha256: '', commit: git('rev-parse', 'HEAD'), fileList: undefined},
  );
  assert.deepEqual(feed(), [
    stable.file, earlier, listed('preview-draft.json').file, listed('preview-tabs.json').file,
    'latest.json', 'preview-draft.json', 'preview-tabs.json', 'files',
  ].sort());
  assert.deepEqual(readdirSync(store).sort(), [...new Set(used())].map(hash => hash + '.gz').sort());
  assert.ok(readdirSync(store).includes(engine.sha256 + '.gz'));
  assert.match(publish('--stable').stderr, /already published/);
});
