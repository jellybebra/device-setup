import { run, root, targetArgument } from './common.mjs';
import { join } from 'node:path';

const target = targetArgument();
run(process.execPath, [join(root, 'scripts/prepare-engine.mjs')]);
run(process.execPath, [join(root, 'scripts/prepare-helper.mjs'), '--target', target]);
run(process.execPath, [join(root, 'scripts/collect-licenses.mjs')]);
