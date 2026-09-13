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

const modeLabels = { openwrt: '纯 OpenWrt', mihomo: 'Mihomo 原生代理', netfleet: 'NetFleet 增强代理' };
const modePhases: Record<string, string> = {
  checking_mode: '核对当前运行模式', stopping_compatibility: '停止 HTTPS 兼容服务',
  stopping_scheduler: '暂停自动调度', stopping_proxy: '停止代理并清理网络接管',
  restoring_native: '恢复原生代理并检查网络', starting_scheduler: '启动自动调度',
  checking_inputs: '校验运行配置与恢复条件', switching_profile: '切换配置并重启代理核心',
  initializing_exits: '等待出口初始化', measuring: '测量机场节点延迟', resetting_candidates: '初始化候选出口',
  selecting: '测量候选并选择出口', activating_exit: '启用出口并验证路径', probing: '验证业务连通性', rolling_back: '恢复可用运行模式',
};

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
    ? (operation.kind === 'mode' && modePhases[operation.phase]) || operationPhases[operation.phase] || '处理中' : operation.state === 'failed' ? '执行失败' : '已完成';
  const title = operation.kind === 'mode' ? '运行模式切换' : operation.kind === 'configuration' ? '配置应用' : operation.kind === 'subscription' ? '机场订阅更新' : operation.kind === 'selection' ? '测速与自动选优' : operation.subject === 'feed' ? '软件包源检查' : '组件更新';
  const details = <>
      <strong>{state}</strong>
      {operation.subject && <span>{operation.kind === 'packages' ? ({ feed: '更新源', netfleet: 'NetFleet', mihomo: 'Mihomo' } as Record<string, string>)[operation.subject] || operation.subject : (operation.kind === 'mode' ? '出口：' : '') + (subjectLabel || operation.subject)}</span>}
      {(operation.total ?? 0) > 0 && <span>{operation.kind === 'subscription' ? '已处理' : '已完成'} {operation.completed} / {operation.total} 个{operation.phase === 'resetting_candidates' ? '候选组' : operation.kind === 'subscription' ? '机场' : ['selection', 'mode'].includes(operation.kind) ? '出口' : '文件'}</span>}
      {!active && <span>{operation.finished_at ? resultTime(operation.finished_at) : operation.updated_at ? `${resultTime(operation.updated_at, '记录更新于')}（完成时间未记录）` : '完成时间未记录'}</span>}
      {elapsed !== null && <span>{active ? '已耗时' : '耗时'} {elapsed < 60 ? `${elapsed} 秒` : `${Math.floor(elapsed / 60)} 分 ${elapsed % 60} 秒`}</span>}
      {operation.error && <span>{componentError(operation.error)}</span>}
      {operation.failure_detail && <details><summary>查看失败详情</summary><p>{[
        operation.failure_detail.group && `候选组：${operation.failure_detail.group}`,
        operation.failure_detail.http_status ? `HTTP ${operation.failure_detail.http_status}` : '未收到控制接口响应',
        operation.failure_detail.transport_code ? `连接错误码：${operation.failure_detail.transport_code}` : null,
        `尝试 ${operation.failure_detail.attempts} 次`,
      ].filter(Boolean).join('；')}</p></details>}
      {operation.recovery && <span>{{ restored: '已恢复更新前状态', failed: operation.kind === 'mode' ? '恢复结果未通过确认' : '恢复失败', direct: '已恢复网络直通', native: '已恢复 Mihomo 原生代理', unchanged: '已确认保持原运行模式' }[operation.recovery]}</span>}
      {operation.kind === 'mode' && <>
        {operation.requested_mode && <span>目标：{modeLabels[operation.requested_mode]}</span>}
        {!active && <span>{operation.actual_mode ? `完成时确认：${modeLabels[operation.actual_mode]}` : '完成时运行模式未确认'}</span>}
        {active && <span>可继续浏览，进度会自动更新。</span>}
      </>}
  </>;
  if (!active) return <ResultNotice scope={scope} slot={operation.kind} identity={JSON.stringify([operation.id, operation.started_at, operation.state, operation.finished_at, operation.recovery])} title={title} warning={warning}>{details}</ResultNotice>;
  return <section className={`nf-operation${warning ? ' is-warning' : ''}`} role="status" aria-live="polite">
    <div className="nf-operation-heading"><Icon aria-hidden="true" className={active && !uncertain ? 'is-spinning' : ''} /><strong>{title}</strong></div>
    <div className="nf-operation-detail">{details}</div>
  </section>;
}
