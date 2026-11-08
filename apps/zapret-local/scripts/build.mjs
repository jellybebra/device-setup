import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { root, run, output, targetArgument } from './common.mjs';

if (process.platform !== 'darwin') throw new Error('The application must be built on macOS.');
const target = targetArgument();
const archTargets = target === 'universal-apple-darwin'
  ? ['aarch64-apple-darwin', 'x86_64-apple-darwin'] : [target];
const { version } = JSON.parse(readFileSync(join(root, 'package.json')));
if (!/^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/.test(version)) throw new Error('Invalid package version.');
if (!process.argv.includes('--ui-only')) {
  run(process.execPath, [join(root, 'scripts/prepare-release.mjs'), '--target', target]);
}
const resources = join(root, 'resources/engine');
const helper = join(root, 'binaries', `zapret-helper-${target}`);
if (!existsSync(helper) || !existsSync(join(resources, 'manifest.json'))) {
  throw new Error('Prepared helper/engine missing. Run the full build first.');
}
const compiled = join(root, '.build/swift', target);
mkdirSync(compiled, { recursive: true });
const sdk = output('xcrun', ['--show-sdk-path']);
const sources = readdirSync(join(root, 'swift')).filter(name => name.endsWith('.swift')).sort().map(name => join(root, 'swift', name));
if (!sources.length) throw new Error('SwiftUI application sources are missing.');
const binaries = [];
for (const arch of archTargets) {
  const outputPath = join(compiled, `zapret-local-${arch}`);
  const swiftTarget = arch === 'aarch64-apple-darwin' ? 'arm64-apple-macos14.0' : 'x86_64-apple-macos14.0';
  run('xcrun', ['swiftc', ...sources, '-parse-as-library', '-O', '-module-name', 'ZapretLocal',
    '-target', swiftTarget, '-sdk', sdk, '-framework', 'SwiftUI', '-framework', 'AppKit',
    '-framework', 'Security', '-framework', 'ServiceManagement', '-o', outputPath]);
  binaries.push(outputPath);
}
const app = join(root, 'dist', target, 'Zapret Local.app');
if (existsSync(app)) rmSync(app, { recursive: true });
const macos = join(app, 'Contents/MacOS');
const bundledResources = join(app, 'Contents/Resources');
mkdirSync(macos, { recursive: true });
mkdirSync(bundledResources, { recursive: true });
if (binaries.length === 2) run('/usr/bin/lipo', ['-create', ...binaries, '-output', join(macos, 'zapret-local')]);
else cpSync(binaries[0], join(macos, 'zapret-local'));
cpSync(helper, join(macos, 'zapret-helper'));
cpSync(resources, join(bundledResources, 'engine'), { recursive: true });
for (const name of ['icon.icns', 'tray.png', 'tray@2x.png']) {
  cpSync(join(root, 'resources/icons', name), join(bundledResources, name));
}
writeFileSync(join(app, 'Contents/PkgInfo'), 'APPL????');
writeFileSync(join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.jellybebra.zapret-local</string>
  <key>CFBundleName</key><string>Zapret Local</string>
  <key>CFBundleDisplayName</key><string>Zapret Local</string>
  <key>CFBundleExecutable</key><string>zapret-local</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version.split('-')[0]}</string>
  <key>CFBundleIconFile</key><string>icon.icns</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
`);
for (const path of [join(macos, 'zapret-local'), join(macos, 'zapret-helper'), join(bundledResources, 'engine/utunws')]) {
  run('/usr/bin/codesign', ['--force', '--sign', '-', path]);
}
run(process.execPath, [join(root, 'scripts/package-dmg.mjs'), '--target', target]);
