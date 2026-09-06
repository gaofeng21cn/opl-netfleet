import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import { OperationProgress, operationRunning } from './OperationProgress';
import { ComponentsView } from '../views/ComponentsView';
import type { OperationSnapshot } from '../types';

const operation: OperationSnapshot = { id: 'operation-1', kind: 'subscription', state: 'running', phase: 'downloading', started_at: 100, updated_at: 111, completed: 1, total: 3, subject: 'Alpha' };

describe('operation progress', () => {
  it('shows measured phase, subject, counts and elapsed time without inventing a percent', () => {
    const html = renderToStaticMarkup(<OperationProgress operation={operation} now={113} />);
    expect(html).toContain('下载中');
    expect(html).toContain('Alpha');
    expect(html).toContain('已处理 1 / 3 个机场');
    expect(html).toContain('已耗时 13 秒');
    expect(html).not.toContain('%');
  });

  it('distinguishes an interrupted connection from confirmed execution failure', () => {
    const unknown = renderToStaticMarkup(<OperationProgress operation={operation} error="network error" now={113} />);
    expect(unknown).toContain('结果尚未确认');
    expect(unknown).not.toContain('执行失败');
    const failed = renderToStaticMarkup(<OperationProgress operation={{ ...operation, state: 'failed', finished_at: 112 }} now={200} />);
    expect(failed).toContain('执行失败');
    expect(failed).toContain('已耗时 12 秒');
  });

  it('does not replace missing live component data with mock versions', () => {
    const html = renderToStaticMarkup(<ComponentsView snapshot={null} operation={null} error="设备未提供组件信息" operationError={null} loading={false} onRead={() => {}} />);
    expect(html).toContain('设备未提供组件信息');
    expect(html).not.toContain('0.5.2');
    expect(html).not.toContain('1.19.30');
  });

  it('keeps a failed update distinct from its separately confirmed recovery outcome', () => {
    for (const [recovery, expected] of [['restored', '已恢复更新前状态'], ['failed', '恢复失败'], ['direct', '已恢复网络直通']] as const) {
      const result = { ...operation, state: 'failed' as const, recovery };
      const html = renderToStaticMarkup(<OperationProgress operation={result} />);
      expect(html).toContain('执行失败');
      expect(html).toContain(expected);
      expect(html).not.toContain('已完成');
      expect(operationRunning(result)).toBe(false);
    }
  });
});
