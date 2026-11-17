import { existsSync, mkdirSync, mkdtempSync, rmSync, readFileSync, writeFileSync, copyFileSync, chmodSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { root, revision, upstream, payloads, lists, run, output } from './common.mjs';

if (process.platform !== 'darwin') throw new Error('The native engine must be built on macOS.');
const build = join(root, '.build');
mkdirSync(build, { recursive: true });
const checkout = process.env.ZAPRET_ENGINE_CHECKOUT
  ? resolve(process.env.ZAPRET_ENGINE_CHECKOUT)
  : join(build, 'flowseal-source');
if (!existsSync(checkout)) {
  if (process.env.ZAPRET_ENGINE_CHECKOUT) throw new Error('ZAPRET_ENGINE_CHECKOUT does not exist.');
  const mirror = join(build, 'flowseal.git');
  if (!existsSync(mirror)) run('git', ['init', '--bare', mirror]);
  run('git', ['--git-dir', mirror, 'fetch', '--depth=1', upstream, revision]);
  run('git', ['--git-dir', mirror, 'worktree', 'add', '--detach', checkout, revision]);
}
if (output('git', ['-C', checkout, 'rev-parse', 'HEAD']) !== revision) {
  throw new Error('Engine checkout is not at the pinned revision.');
}
if (output('git', ['-C', checkout, 'status', '--porcelain', '--untracked-files=no'])) {
  throw new Error('Engine checkout has modified tracked sources.');
}
const sdk = output('xcrun', ['--show-sdk-path']);
const destination = join(root, 'resources/engine');
mkdirSync(destination, { recursive: true });
const dist = join(build, 'dist');
mkdirSync(dist, { recursive: true });
const stage = mkdtempSync(join(build, 'engine-src-'));
try {
  const prefix = 'flowseal-' + revision;
  const source = join(stage, prefix);
  const archive = join(stage, 'source.tar');
  run('git', ['-C', checkout, 'archive', '--format=tar', '--prefix=' + prefix + '/', '--output=' + archive, revision]);
  run('tar', ['-xf', archive, '-C', stage]);
  run('/usr/bin/patch', ['-p1', '-i', join(root, 'native/utunws-wssize-ramp.patch')], { cwd: source });
  copyFileSync(join(root, 'native/wssize_ramp.h'), join(source, 'nfq/wssize_ramp.h'));
  run('tar', ['-czf', join(dist, `flowseal-source-${revision.slice(0, 12)}.tar.gz`), '-C', stage, prefix]);
  run('make', ['-C', join(source, 'nfq'), 'mac', `SDKROOT=${sdk}`]);
  copyFileSync(join(source, 'nfq/utunws'), join(destination, 'utunws'));
  chmodSync(join(destination, 'utunws'), 0o755);
} finally {
  rmSync(stage, { recursive: true, force: true });
}
for (const name of payloads) {
  copyFileSync(join(checkout, 'macos/Payload/bin', name), join(destination, name));
  chmodSync(join(destination, name), 0o644);
}
for (const name of lists) {
  const source = name === 'cloudflare-ipv4.txt'
    ? join(root, '../../configs/cudy-tr3000', name)
    : name === 'strategies.json'
    ? join(root, 'resources', name)
    : join(checkout, 'macos/Payload', name.startsWith('ipset-any') || name.startsWith('ipset-none') ? '' : 'default-lists', name);
  copyFileSync(source, join(destination, name));
}
// Keep the application's existing social sites available in every upstream preset.
writeFileSync(join(destination, 'list-general-user.txt'), 'instagram.com\ncdninstagram.com\nigcdn.com\nig.me\nfbcdn.net\nx.com\ntwitter.com\ntwimg.com\nt.co\n');
// Sign before hashing. The final bundle step refreshes the manifest after
// nested-code signing, then signs the outer app without modifying nested code.
run('/usr/bin/codesign', ['--force', '--sign', '-', join(destination, 'utunws')]);
const hashes = Object.fromEntries(['utunws', ...payloads, ...lists].map(name => [name,
  createHash('sha256').update(readFileSync(join(destination, name))).digest('hex')]));
writeFileSync(join(destination, 'manifest.json'), JSON.stringify({ source: upstream.replace(/\.git$/, ''), commit: revision, sha256: hashes }, null, 2) + '\n');
copyFileSync(join(checkout, 'LICENSE'), join(destination, 'FLOWSEAL-LICENSE.txt'));
copyFileSync(join(root, 'THIRD_PARTY_NOTICES.md'), join(destination, 'THIRD_PARTY_NOTICES.md'));
console.log(`Built pinned universal Flowseal engine in ${destination}`);
