import { existsSync, mkdirSync, readFileSync, readdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { root, output } from './common.mjs';

const destination = join(root, 'resources/engine/licenses');
mkdirSync(destination, { recursive: true });
const records = [];
const licenseName = /^(licen[sc]e|copying|notice|unlicense)([._-].*)?$/i;
function collect(kind, name, version, directory, declaredLicense, source) {
  const safeName = `${kind}-${name.replaceAll(/[^A-Za-z0-9._-]/g, '_')}-${version}`;
  const target = join(destination, safeName);
  const files = readdirSync(directory, { withFileTypes: true }).filter(entry => entry.isFile() && licenseName.test(entry.name));
  if (files.length) mkdirSync(target, { recursive: true });
  for (const file of files) copyFileSync(join(directory, file.name), join(target, file.name));
  records.push({ ecosystem: kind, name, version, license: declaredLicense || 'see upstream source',
    source, notices: files.map(file => `${safeName}/${file.name}`) });
}
const metadata = JSON.parse(output('cargo', ['metadata', '--locked', '--format-version', '1']));
for (const pkg of metadata.packages) {
  if (!pkg.source) continue; // The application's own workspace source.
  collect('cargo', pkg.name, pkg.version, dirname(pkg.manifest_path), pkg.license,
    pkg.repository || `https://crates.io/crates/${pkg.name}/${pkg.version}`);
}
const npmLock = JSON.parse(readFileSync(join(root, 'package-lock.json')));
for (const [folder, entry] of Object.entries(npmLock.packages || {})) {
  if (!folder.startsWith('node_modules/')) continue;
  const directory = resolve(root, folder);
  if (!directory.startsWith(join(root, 'node_modules') + '/') || !existsSync(join(directory, 'package.json'))) continue;
  const pkg = JSON.parse(readFileSync(join(directory, 'package.json')));
  collect('npm', pkg.name, pkg.version, directory, pkg.license,
    typeof pkg.repository === 'string' ? pkg.repository : pkg.repository?.url || `https://www.npmjs.com/package/${pkg.name}/v/${pkg.version}`);
}
records.sort((a, b) => `${a.ecosystem}/${a.name}`.localeCompare(`${b.ecosystem}/${b.name}`));
writeFileSync(join(destination, 'index.json'), JSON.stringify(records, null, 2) + '\n');
console.log(`Bundled license notices for ${records.length} locked dependencies.`);
