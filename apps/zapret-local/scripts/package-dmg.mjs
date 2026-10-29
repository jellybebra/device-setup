import { copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { root, revision, payloads, run, targetArgument, output } from './common.mjs';

const target = targetArgument();
const config = JSON.parse(readFileSync(join(root, 'package.json')));
const name = 'Zapret Local';
const version = config.version;
if (typeof name !== 'string' || typeof version !== 'string') throw new Error('Explicit productName/version are required.');
const app = join(root, 'dist', target, `${name}.app`);
if (!existsSync(app)) throw new Error(`App bundle missing: ${app}. Run npm run build first.`);
const engine = join(app, 'Contents/Resources/engine');
const manifestPath = join(engine, 'manifest.json');
if (!existsSync(manifestPath)) throw new Error('Bundle is missing Contents/Resources/engine.');
const manifest = JSON.parse(readFileSync(manifestPath));
if (manifest.commit !== revision) throw new Error('Unexpected engine revision in bundle.');
// The build signs nested executables while assembling the app. Signing can change
// Mach-O bytes, so the installer manifest must describe the final binary.
for (const file of ['utunws', ...payloads]) {
  manifest.sha256[file] = createHash('sha256').update(readFileSync(join(engine, file))).digest('hex');
}
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
run('/usr/bin/codesign', ['--force', '--sign', '-', app]);
run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
for (const binary of ['Contents/MacOS/zapret-local', 'Contents/MacOS/zapret-helper', 'Contents/Resources/engine/utunws']) {
  const arches = output('/usr/bin/lipo', ['-archs', join(app, binary)]);
  if (target === 'universal-apple-darwin' && (!arches.includes('arm64') || !arches.includes('x86_64'))) {
    throw new Error(`Universal bundle contains a single-architecture binary: ${binary}`);
  }
}
const dist = join(root, '.build/dist');
mkdirSync(dist, { recursive: true });
const stage = join(root, '.build/dmg-stage');
if (existsSync(stage)) rmSync(stage, { recursive: true });
mkdirSync(stage);
cpSync(app, join(stage, `${name}.app`), { recursive: true, verbatimSymlinks: true });
symlinkSync('/Applications', join(stage, 'Applications'));
copyFileSync(join(root, 'THIRD_PARTY_NOTICES.md'), join(stage, 'THIRD_PARTY_NOTICES.txt'));
const arch = target === 'universal-apple-darwin' ? 'universal' : target.split('-')[0];
const dmg = join(dist, `Zapret-Local_${version}_${arch}.dmg`);
run('/usr/bin/hdiutil', ['create', '-volname', name, '-srcfolder', stage, '-format', 'UDZO', '-fs', 'HFS+', '-ov', dmg]);
run('/usr/bin/hdiutil', ['verify', dmg]);
rmSync(stage, { recursive: true });
const assets = readdirSync(dist).filter(file => file.endsWith('.dmg') || file.startsWith('flowseal-source-'));
writeFileSync(join(dist, 'SHA256SUMS.txt'), assets.sort().map(file =>
  `${createHash('sha256').update(readFileSync(join(dist, file))).digest('hex')}  ${file}`
).join('\n') + '\n');
console.log(`Ready to install: ${dmg}`);
