import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const src = join(dirname(fileURLToPath(import.meta.url)));
const read = (name: string) => readFileSync(join(src, name), 'utf8');

describe('Vite 开发入口', () => {
  it('不包裹 StrictMode，首次 live 只通过一次 snapshot 读取', () => {
    const main = read('main.tsx');
    const app = read('App.tsx');
    const liveClient = read('api/liveClient.ts');

    expect(main).not.toContain('StrictMode');
    expect(main).toContain('reactRoot.render(<DevApp />)');
    expect(liveClient).not.toContain('inflightRead');
    expect(liveClient.match(/\/__netfleet_live\/snapshot/g)).toEqual(['/__netfleet_live/snapshot']);
    expect(app.match(/client\.read\(\)/g)).toEqual(['client.read()']);
  });
});
