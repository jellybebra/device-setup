import { mkdirSync, copyFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import { root, run, targetArgument, targetDirectory } from './common.mjs';

const target = targetArgument();
const arches = target === 'universal-apple-darwin'
  ? ['aarch64-apple-darwin', 'x86_64-apple-darwin'] : [target];
for (const arch of arches) {
  run('cargo', ['build', '--locked', '--release', '--package', 'zapret-helper', '--target', arch], {
    env: { ...process.env, MACOSX_DEPLOYMENT_TARGET: '14.0' },
  });
}
const directory = join(root, 'binaries');
mkdirSync(directory, { recursive: true });
const destination = join(directory, `zapret-helper-${target}`);
const binaries = arches.map(arch => join(targetDirectory(), arch, 'release/zapret-helper'));
if (binaries.length === 2) run('/usr/bin/lipo', ['-create', ...binaries, '-output', destination]);
else copyFileSync(binaries[0], destination);
chmodSync(destination, 0o755);
run('/usr/bin/codesign', ['--force', '--sign', '-', destination]);
console.log(`Prepared ${destination}`);
