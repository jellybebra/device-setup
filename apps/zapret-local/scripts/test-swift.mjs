import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { root, run } from './common.mjs';

const target = process.arch === 'arm64' ? 'arm64-apple-macos14.0' : 'x86_64-apple-macos14.0';
const output = join(root, '.build/tests');
mkdirSync(output, { recursive: true });
const binary = join(output, 'lifecycle-tests');
run('xcrun', ['swiftc', ...['HelperClient', 'Authorization', 'VLESSProfile', 'ProxyServer', 'ServerLibrary', 'ProcessShutdown', 'ServerProbes', 'ProxyModel']
  .map(name => join(root, 'swift', `${name}.swift`)), join(root, 'tests/LifecycleTests.swift'),
  '-parse-as-library', '-target', target, '-o', binary]);
run(binary, []);
