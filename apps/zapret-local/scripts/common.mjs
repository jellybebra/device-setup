import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const revision = '94c3b5125b4904ce2f6aec0e2197fe17f2fadf14';
export const upstream = 'https://github.com/Flowseal/zapret-mac-discord-youtube.git';
export const payloads = ['ACTIVE_DISCORD_UDP.bin', 'quic_initial_www_google_com.bin', 'tls_clienthello_www_google_com.bin'];

export function run(program, args, options = {}) {
  return execFileSync(program, args, { cwd: root, stdio: 'inherit', ...options });
}

export function output(program, args, options = {}) {
  return run(program, args, { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8', ...options }).trim();
}

export function targetArgument(args = process.argv.slice(2)) {
  const i = args.indexOf('--target');
  const target = i >= 0 ? args[i + 1] : process.env.ZAPRET_BUILD_TARGET;
  const resolved = target || output('rustc', ['-vV']).match(/^host: (.+)$/m)?.[1];
  if (!['aarch64-apple-darwin', 'x86_64-apple-darwin', 'universal-apple-darwin'].includes(resolved)) {
    throw new Error(`Unsupported macOS target: ${resolved}`);
  }
  return resolved;
}

export function targetDirectory() {
  return resolve(root, process.env.CARGO_TARGET_DIR || 'target');
}
