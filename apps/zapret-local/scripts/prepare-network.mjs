import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { output, root, run, targetArgument } from './common.mjs';

const target = targetArgument();
const arches = target.startsWith('universal') ? ['arm64', 'amd64'] :
  [target.startsWith('aarch64') ? 'arm64' : 'amd64'];
const cache = join(root, '.build/network');
const destination = join(root, 'binaries', 'network-' + target);
mkdirSync(destination, { recursive: true });
const inputs = { 'sing-box': [], xray: [], 'cudy-dns': [], 'system-dns': [] };
for (const arch of arches) {
  const dir = join(cache, arch);
  mkdirSync(dir, { recursive: true });
  const sing = 'sing-box-1.14.3-darwin-' + arch;
  const xray = 'Xray-macos-' + (arch === 'arm64' ? 'arm64-v8a' : '64') + '.zip';
  const assets = [
    ['sing-box', 'https://github.com/SagerNet/sing-box/releases/download/v1.14.3/' + sing + '.tar.gz',
      arch === 'arm64' ? '0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5' : '6d002b74d03b478547349cc10af89e007868596e5aa931816d45da9f544715a9'],
    ['xray', 'https://github.com/XTLS/Xray-core/releases/download/v26.11.9/' + xray,
      arch === 'arm64' ? '233f0c66681cd0726f81a6b2b6ed6a5710869e312047b522e46ed53035bebd26' : '488963e676e06f5e48547f9dd38116aaca8de4234959b4272ae8f284e658dfd0'],
  ];
  for (const [name, url, digest] of assets) {
    const archive = join(dir, url.split('/').pop());
    if (!existsSync(archive) || createHash('sha256').update(readFileSync(archive)).digest('hex') !== digest) {
      const partial = archive + '.download';
      run('curl', ['-fLsS', '--connect-timeout', '12', '--max-time', '180', '--retry-all-errors', '--retry', '2', '-o', partial, url]);
      if (createHash('sha256').update(readFileSync(partial)).digest('hex') !== digest) throw Error('Download checksum mismatch: ' + name);
      renameSync(partial, archive);
    }
    if (createHash('sha256').update(readFileSync(archive)).digest('hex') !== digest) throw Error('Invalid archive: ' + archive);
    if (name === 'xray') run('unzip', ['-oq', archive, 'xray', 'LICENSE', '-d', dir]);
    else run('tar', ['-xzf', archive, '-C', dir, sing + '/sing-box', sing + '/LICENSE']);
    copyFileSync(name === 'xray' ? join(dir, 'LICENSE') : join(dir, sing, 'LICENSE'), join(destination, name + '-LICENSE'));
    inputs[name].push(name === 'xray' ? join(dir, name) : join(dir, sing, name));
  }
  const dns = join(dir, 'cudy-dns');
  run('go', ['build', '-trimpath', '-o', dns, '.'], { cwd: join(root, 'dns'),
    env: { ...process.env, CGO_ENABLED: '0', GOOS: 'darwin', GOARCH: arch } });
  inputs['cudy-dns'].push(dns);
  const resolver = join(dir, 'system-dns');
  run('xcrun', ['swiftc', '-O', '-target', (arch === 'amd64' ? 'x86_64' : arch) + '-apple-macos14.0',
    join(root, 'scripts/system-dns.swift'), '-o', resolver]);
  inputs['system-dns'].push(resolver);
}
for (const [name, files] of Object.entries(inputs)) {
  const dest = join(destination, name);
  if (files.length > 1) run('lipo', ['-create', ...files, '-output', dest]);
  else copyFileSync(files[0], dest);
  chmodSync(dest, 0o755);
  run('/usr/bin/codesign', ['--force', '--sign', '-', dest]);
  console.log(name, output('lipo', ['-archs', dest]));
}
