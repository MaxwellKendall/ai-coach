// TKL-768: Swift package versions are pinned, so every fresh checkout, worktree or CI run
// builds the same dependency graph. The tracked Package.resolved is the source of truth;
// `xcodegen generate` copies it into the (gitignored) AICoach.xcodeproj.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const tracked = join(root, 'Package.resolved');
const generated = join(root, 'AICoach.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved');
const spec = readFileSync(join(root, 'project.yml'), 'utf8');

const pin = (resolved, identity) => resolved.pins.find((p) => p.identity === identity);

test('a Package.resolved is tracked at the repo root and pins amplify-swift', () => {
  assert.ok(existsSync(tracked), 'Package.resolved missing at the repo root');
  const amplify = pin(JSON.parse(readFileSync(tracked, 'utf8')), 'amplify-swift');
  assert.ok(amplify, 'amplify-swift not pinned in Package.resolved');
  assert.match(amplify.state.version, /^\d+\.\d+\.\d+$/);
});

test('project.yml pins amplify-swift to the exact version in Package.resolved', () => {
  const amplify = pin(JSON.parse(readFileSync(tracked, 'utf8')), 'amplify-swift');
  const m = spec.match(/Amplify:\s*\n\s*url: \S+\s*\n\s*exactVersion: (\S+)/);
  assert.ok(m, 'project.yml should give Amplify an exactVersion, not a range');
  assert.equal(m[1].replace(/"/g, ''), amplify.state.version);
});

test('xcodegen generate copies the tracked Package.resolved into the project', (t) => {
  try {
    execFileSync('xcodegen', ['--version'], { stdio: 'ignore' });
  } catch {
    t.skip('xcodegen not installed');
    return;
  }
  execFileSync('xcodegen', ['generate', '--quiet'], { cwd: root, stdio: 'inherit' });
  assert.ok(existsSync(generated), 'no Package.resolved inside AICoach.xcodeproj after xcodegen generate');
  assert.equal(readFileSync(generated, 'utf8'), readFileSync(tracked, 'utf8'));
});
