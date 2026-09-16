import { describe, expect, it } from 'vitest';
import { hostAccentTokens } from './hostTheme';
import { reportHostState, saveBackupThroughHost } from './hostBridge';

describe('宿主强调色的界面投影', () => {
  it('缺少宿主值时保留共享主题色', () => {
    expect(hostAccentTokens(null)).toBeNull();
    expect(hostAccentTokens(undefined)).toBeNull();
    expect(hostAccentTokens('blue')).toBeNull();
  });
  it('深色强调色配白字，浅色强调色配黑字', () => {
    expect(hostAccentTokens('#0000ff')?.foreground).toBe('#ffffff');
    expect(hostAccentTokens('#ffe600')?.foreground).toBe('#000000');
  });
  it('派生色保持同一色相并可直接用于 token', () => {
    expect(hostAccentTokens('#3366cc')).toEqual({
      accent: '#3366cc', strong: '#2b56ab', soft: '#ebf0fa', border: '#a3bae8', foreground: '#ffffff',
    });
  });
});

describe('宿主桥接', () => {
  it('没有宿主处理器时不发送，也不阻塞浏览器回退路径', () => {
    expect(saveBackupThroughHost('{}')).toBe(false);
    expect(() => reportHostState({
      running: false, configured: false, busy: false, mode: 'direct', networkMode: 'explicit',
      address: '', summary: '代理已停止', exits: [], automationPaused: false,
    })).not.toThrow();
  });
  it('存在宿主处理器时按名称发送页面状态与备份内容', () => {
    const calls: Array<[string, unknown]> = [];
    const runtime = globalThis as unknown as { window?: unknown };
    const previous = runtime.window;
    runtime.window = { webkit: { messageHandlers: {
      netfleetState: { postMessage: (value: unknown) => calls.push(['state', value]) },
      saveBackup: { postMessage: (value: unknown) => calls.push(['backup', value]) },
    } } };
    try {
      expect(saveBackupThroughHost('{"ok":true}')).toBe(true);
      reportHostState({
        running: true, configured: true, busy: false, mode: 'netfleet', networkMode: 'system',
        address: '127.0.0.1:7890', summary: '海外加速 日本', automationPaused: false,
        exits: [{ id: 'standard', name: '海外加速', current: '日本', detail: '86 ms · 健康', automatic: true, paused: false, selectable: true, regions: [{ id: 'japan', name: '日本', selected: true }] }],
      });
      expect(calls).toEqual([
        ['backup', { contents: '{"ok":true}' }],
        ['state', {
          running: true, configured: true, busy: false, mode: 'netfleet', networkMode: 'system',
          address: '127.0.0.1:7890', summary: '海外加速 日本', automationPaused: false,
          exits: [{ id: 'standard', name: '海外加速', current: '日本', detail: '86 ms · 健康', automatic: true, paused: false, selectable: true, regions: [{ id: 'japan', name: '日本', selected: true }] }],
        }],
      ]);
    } finally { runtime.window = previous; }
  });
});
