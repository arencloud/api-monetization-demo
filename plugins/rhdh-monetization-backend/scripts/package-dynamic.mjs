import { statSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const pluginRoot = resolve(import.meta.dirname, '..');
const dynamicRoot = resolve(pluginRoot, 'dist-dynamic');
if (!statSync(resolve(dynamicRoot, 'package.json')).isFile()) {
  throw new Error('dist-dynamic is missing; run npm run export-dynamic -- --clean first');
}
const destination = resolve(pluginRoot, '../../platform/developer-hub');
const packed = spawnSync(
  'npm',
  ['pack', '--pack-destination', destination, dynamicRoot],
  { cwd: pluginRoot, encoding: 'utf8', stdio: 'inherit' },
);
if (packed.status !== 0) process.exit(packed.status ?? 1);
