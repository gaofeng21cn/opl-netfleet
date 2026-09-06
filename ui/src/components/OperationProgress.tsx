import { CheckCircle2, LoaderCircle, TriangleAlert } from 'lucide-react';
import type { OperationSnapshot } from '../types';
import { componentError } from '../lib/componentError';

export const operationPhases: Record<string, string> = {
  preparing: '准备更新', checking: '检查更新源', downloading: '下载中', validating: '校验内容',
  compiling: '生成运行配置', reloading: '重载运行配置', selecting: '重新选优',
  installing: '安装组件', verifying: '确认运行状态', rolling_back: '恢复更新前状态', done: '已完成',
};

export const operationRunning = (operation?: OperationSnapshot | null) => operation?.state === 'running' || operation?.state === 'queued';

export function OperationProgress({ operation, error, now = Date.now() / 1000 }: { operation: OperationSnapshot | null; error?: string | null; now?: number }) {
  if (!operation) return error ? <div className="nf-alert" role="status">{error}</div> : null;
  const active = operationRunning(operation);
  const uncertain = Boolean(error && active) || operation.state === 'interrupted';
  const warning = uncertain || operation.state === 'failed';
  const Icon = warning ? TriangleAlert : active ? LoaderCircle : CheckCircle2;
  const elapsed = Math.max(0, Math.floor((operation.finished_at || now) - operation.started_at));
  const state = uncertain ? '连接或执行已中断，结果尚未确认' : operation.state === 'queued' ? '已提交，等待设备执行' : operation.state === 'running'
    ? operationPhases[operation.phase] || '处理中' : operation.state === 'failed' ? '执行失败' : '已完成';
  return <section className={`nf-operation${warning ? ' is-warning' : ''}`} role="status" aria-live="polite">
    <div className="nf-operation-heading"><Icon aria-hidden="true" className={active && !uncertain ? 'is-spinning' : ''} /><strong>{operation.kind === 'subscription' ? '机场订阅更新' : '组件与更新'}</strong></div>
    <div className="nf-operation-detail">
      <strong>{state}</strong>
      {operation.subject && <span>{operation.kind === 'packages' ? ({ feed: '更新源', netfleet: 'NetFleet', mihomo: 'Mihomo' } as Record<string, string>)[operation.subject] || operation.subject : operation.subject}</span>}
      {(operation.total ?? 0) > 0 && <span>{operation.kind === 'subscription' ? '已处理' : '已完成'} {operation.completed} / {operation.total} 个{operation.kind === 'subscription' ? '机场' : '文件'}</span>}
      <span>已耗时 {elapsed < 60 ? `${elapsed} 秒` : `${Math.floor(elapsed / 60)} 分 ${elapsed % 60} 秒`}</span>
      {operation.error && <span>{componentError(operation.error)}</span>}
    </div>
  </section>;
}
