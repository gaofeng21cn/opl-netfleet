import { CheckCircle2, LoaderCircle, TriangleAlert } from 'lucide-react';
import { useEffect, useReducer } from 'react';
import type { OperationSnapshot } from '../types';
import { componentError } from '../lib/componentError';
import { ResultNotice, resultTime } from './ResultNotice';

export const operationPhases: Record<string, string> = {
  snapshotting: '保存恢复点', deactivating: '退出旧配置', saving: '保存配置', activating: '启用配置并检查网络',
  preparing: '准备更新', checking: '检查更新源', downloading: '下载中', validating: '校验内容',
  compiling: '生成运行配置', reloading: '重载运行配置', selecting: '重新选优',
  installing: '安装组件', verifying: '确认运行状态', rolling_back: '恢复更新前状态', done: '已完成',
};

export const operationRunning = (operation?: OperationSnapshot | null) => operation?.state === 'running' || operation?.state === 'queued';

const observations = new Map<string, { identity: string; seenAt: number; expiresAt?: number }>();
function observe(operation: OperationSnapshot | null, scope: string) {
  if (!operation) return null;
  const key = `netfleet:observed:v1:${scope}:${operation.kind}`;
  let record = observations.get(key);
  if (!record) { try { record = JSON.parse(sessionStorage.getItem(key) || 'null'); } catch { /* Storage is optional. */ } }
  const now = Date.now(), identity = JSON.stringify([operation.id, operation.started_at]);
  if (operationRunning(operation)) record = { identity, seenAt: now };
  else if (!record || record.identity !== identity || !record.expiresAt && now - record.seenAt >= 60000) return null;
  else if (!record.expiresAt) record.expiresAt = now + 60000;
  observations.set(key, record);
  try { sessionStorage.setItem(key, JSON.stringify(record)); } catch { /* No source data is stored. */ }
  return record.expiresAt || null;
}

export function OperationProgress({ operation, error, scope = '', subjectLabel, now = Date.now() / 1000 }: { operation: OperationSnapshot | null; error?: string | null; scope?: string; subjectLabel?: string; now?: number }) {
  const [, redraw] = useReducer(value => value + 1, 0);
  const expiresAt = observe(operation, scope);
  useEffect(() => {
    if (!expiresAt || expiresAt <= Date.now()) return;
    const timer = setTimeout(redraw, expiresAt - Date.now() + 1);
    return () => clearTimeout(timer);
  }, [expiresAt]);
  if (!operation) return error ? <div className="nf-alert" role="status">{error}</div> : null;
  if (operation.state === 'succeeded' && (!expiresAt || expiresAt <= Date.now())) return null;
  const active = operationRunning(operation);
  const uncertain = Boolean(error && active) || operation.state === 'interrupted';
  const warning = uncertain || operation.state === 'failed';
  const Icon = warning ? TriangleAlert : active ? LoaderCircle : CheckCircle2;
  const end = active ? now : operation.finished_at;
  const elapsed = end && operation.started_at && end >= operation.started_at ? Math.floor(end - operation.started_at) : null;
  const state = uncertain ? '连接或执行已中断，结果尚未确认' : operation.state === 'queued' ? '已提交，等待设备执行' : operation.state === 'running'
    ? operationPhases[operation.phase] || '处理中' : operation.state === 'failed' ? '执行失败' : '已完成';
  const title = operation.kind === 'configuration' ? '配置应用' : operation.kind === 'subscription' ? '机场订阅更新' : operation.kind === 'selection' ? '测速与自动选优' : operation.subject === 'feed' ? '软件包源检查' : '组件更新';
  const details = <>
      <strong>{state}</strong>
      {operation.subject && <span>{operation.kind === 'packages' ? ({ feed: '更新源', netfleet: 'NetFleet', mihomo: 'Mihomo' } as Record<string, string>)[operation.subject] || operation.subject : subjectLabel || operation.subject}</span>}
      {(operation.total ?? 0) > 0 && <span>{operation.kind === 'subscription' ? '已处理' : '已完成'} {operation.completed} / {operation.total} 个{operation.kind === 'subscription' ? '机场' : operation.kind === 'selection' ? '出口' : '文件'}</span>}
      {!active && <span>{operation.finished_at ? resultTime(operation.finished_at) : operation.updated_at ? `${resultTime(operation.updated_at, '记录更新于')}（完成时间未记录）` : '完成时间未记录'}</span>}
      {elapsed !== null && <span>{active ? '已耗时' : '耗时'} {elapsed < 60 ? `${elapsed} 秒` : `${Math.floor(elapsed / 60)} 分 ${elapsed % 60} 秒`}</span>}
      {operation.error && <span>{componentError(operation.error)}</span>}
      {operation.recovery && <span>{{ restored: '已恢复更新前状态', failed: '恢复失败', direct: '已恢复网络直通' }[operation.recovery]}</span>}
  </>;
  if (!active) return <ResultNotice scope={scope} slot={operation.kind} identity={JSON.stringify([operation.id, operation.started_at, operation.state, operation.finished_at, operation.recovery])} title={title} warning={warning}>{details}</ResultNotice>;
  return <section className={`nf-operation${warning ? ' is-warning' : ''}`} role="status" aria-live="polite">
    <div className="nf-operation-heading"><Icon aria-hidden="true" className={active && !uncertain ? 'is-spinning' : ''} /><strong>{title}</strong></div>
    <div className="nf-operation-detail">{details}</div>
  </section>;
}
