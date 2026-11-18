import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import test from 'node:test';

test('only a successful worktree removal retires the branch’s listed previews and exclusive ZIPs', t => {
  const root = mkdtempSync(join(tmpdir(), 'relay-preview-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const main = join(root, 'repo');
  const worktree = join(root, 'feature worktree');
  const releases = join(root, 'feed');
  mkdirSync(main);
  mkdirSync(releases);
  const options = {
    cwd: main,
    env: {...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1'},
    encoding: 'utf8' as const,
  };
  const git = (...args: string[]) => execFileSync('git', args, {...options, stdio: 'pipe'});
  git('init', '-b', 'main');
  git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '--allow-empty', '-m', 'fixture');
  git('worktree', 'add', '-b', 'feature/search', worktree);
  git('config', 'relay.flutterReleases', releases);

  const zip = (char: string) => 'Relay-Flutter-preview-' + char.repeat(64) + '.zip';
  const stable = 'Relay-Flutter-0.0.8-macOS-arm64.zip';
  const listing = (name: string, branch: string, file: string) =>
    writeFileSync(join(releases, 'preview-' + name + '.json'), JSON.stringify({name, branch, file}));
  for (const file of [zip('a'), zip('b'), zip('c'), stable, 'latest.json']) {
    writeFileSync(join(releases, file), 'fixture');
  }
  listing('search', 'feature/search', zip('a'));
  listing('compact', 'feature/search', zip('b'));
  listing('other', 'feature/tabs', zip('b'));

  const remove = () => spawnSync(resolve('tools/remove-worktree'), [worktree], options);
  const feed = () => readdirSync(releases).filter(file => !file.startsWith('.')).sort();
  const before = feed();
  const draft = join(worktree, 'draft');
  writeFileSync(draft, 'uncommitted work');
  assert.notEqual(remove().status, 0);
  assert.ok(existsSync(draft));
  assert.deepEqual(feed(), before);

  rmSync(draft);
  const result = remove();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(existsSync(worktree), false);
  assert.deepEqual(feed(), ['preview-other.json', zip('b'), zip('c'), stable, 'latest.json'].sort());
});
