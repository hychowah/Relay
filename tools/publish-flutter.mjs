import {createReadStream} from 'node:fs';
import {copyFile, mkdir, readFile, rename, stat, writeFile} from 'node:fs/promises';
import {createHash, randomUUID} from 'node:crypto';
import {resolve, join} from 'node:path';
import {execFileSync} from 'node:child_process';

const [archive, destination = 'runtime/flutter/releases'] = process.argv.slice(2);
if (!archive) throw new Error('Usage: node tools/publish-flutter.mjs <Mac ZIP> [release directory]');
const version = (await readFile('flutter/pubspec.yaml', 'utf8')).match(/^version: (\d+\.\d+\.\d+)/m)[1];
const bundle = JSON.parse(execFileSync('python3', ['-c',
  'import json,plistlib,sys,zipfile; p=plistlib.loads(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2]+".app/Contents/Info.plist")); print(json.dumps({"version":p["CFBundleShortVersionString"],"id":p["CFBundleIdentifier"],"preview":p.get("RelayPreview")}))', archive, 'Relay Flutter'], {encoding: 'utf8'}));
if (bundle.preview) throw new Error('Choose a Stable build. Test builds belong in the preview feed.');
if (bundle.version !== version || bundle.id !== 'app.relay.flutterExperiment') throw new Error('Build and archive the current Relay version before publishing.');
const directory = resolve(destination), file = `Relay-Flutter-${version}-macOS-arm64.zip`;
await mkdir(directory, {recursive: true});
try {await stat(join(directory, file)); throw new Error('This version is already published. Increase the version before publishing another build.');}
catch (error) {if (error.code !== 'ENOENT') throw error;}
const pending = join(directory, `.upload-${randomUUID()}`);
await copyFile(archive, pending);
const hash = createHash('sha256');
for await (const chunk of createReadStream(pending)) hash.update(chunk);
const release = {version, file, size: (await stat(pending)).size, sha256: hash.digest('hex')};
await rename(pending, join(directory, file));
const manifest = join(directory, `.manifest-${randomUUID()}`);
await writeFile(manifest, JSON.stringify(release, null, 2) + '\n');
await rename(manifest, join(directory, 'latest.json'));
console.log(`Published Relay ${version} to ${directory}`);
