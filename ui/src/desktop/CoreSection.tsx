import { Info } from 'lucide-react';
import { useEffect, useState } from 'react';
import type { CoreSettingRow, DesktopSnapshot, UpdateStatus } from './types';
import type { DesktopNetFleetClient } from './client';
import type { RunAction } from './panels';
import { installUpdateThroughHost } from './hostBridge';

// 只读投影：值来自 Mac 平台交给核心的配置、特权 TUN 会话实际应用的覆写、
// Profile 声明和运行中核心回读；页面不重新解释映射，也提交不了写入。
const sourceLabels: Record<CoreSettingRow['source'], string> = {
  platform: '平台接管', profile: 'Profile 声明', core_default: '核心默认',
};
const componentSources: Record<string, string> = { running: '运行回读', runtime: '本机回读', package: '随包版本' };
const short = (value: string | null) => value && /^[0-9a-f]{40}$/.test(value) ? value.slice(0, 8) : value;
const value = (input: string | null, fallback: string) => input ?? fallback;

// 更新检查只读缓存结果，超过一天才重新联网；安装面板需要用户确认。
function UpdateSection({ snapshot, client, run, disabled }: {
  snapshot: DesktopSnapshot; client: DesktopNetFleetClient; run: RunAction; disabled: boolean;
}) {
  const [status, setStatus] = useState<UpdateStatus | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [confirmPanel, setConfirmPanel] = useState(false);
  const [confirmApp, setConfirmApp] = useState(false);
  useEffect(() => {
    let active = true;
    const timer = setTimeout(() => {
      client.updateCheck().then(value => { if (active) setStatus(value); }, reason => { if (active) setError(reason instanceof Error ? reason.message : String(reason)); });
    }, 300);
    return () => { active = false; clearTimeout(timer); };
  }, [client]);
  const checkedAt = status ? new Date(status.checked_at * 1000).toLocaleString() : null;
  const panel = status?.panel;
  const app = status?.app;
  const check = () => void run('检查更新', async () => {
    setError(null);
    const value = await client.updateCheck(true);
    setStatus(value);
    return { message: value.errors.length > 0 ? `部分来源检查失败：${value.errors.join('、')}` : '已完成更新检查。', ready: value.errors.length === 0 };
  });
  const install = () => void run('更新面板资源', async () => {
    const result = await client.updateDashboard();
    setStatus(await client.updateCheck());
    return { message: `面板已更新到 ${result.version}。`, ready: true };
  }).then(ok => { if (ok) setConfirmPanel(false); });
  // 应用更新：先校验并暂存，再请宿主优雅退出，由替换进程完成重启。
  const installApp = () => void run('准备应用更新', async () => {
    const result = await client.updateApp();
    if (!installUpdateThroughHost()) throw new Error('更新需要在应用内执行，请重新打开应用后重试。');
    return { message: `已校验 ${result.version} 并暂存；应用退出后会自动替换并重新打开。`, ready: true };
  }).then(ok => { if (ok) setConfirmApp(false); });
  const selfUpdate = app?.self_update;
  const canInstallApp = Boolean(app?.update_available && selfUpdate === 'available' && app?.candidate);
  const selfUpdateNote: Record<string, string> = {
    'local-build': '当前是本地构建（非分发渠道），不自我替换；升级请使用本地构建流程。',
    'dirty-build': '当前构建包含未提交改动，不自我替换。',
    'not-an-app-bundle': '当前运行位置不是应用包，不自我替换。',
    'unsupported-platform': '当前平台不支持应用自更新。',
  };
  return <section className="nf-config-section">
    <div className="nf-config-section-heading">
      <h2>更新</h2>
      <p>检查上游面板与已发布的 macOS 应用版本；安装始终需要确认，不自动替换任何文件。</p>
    </div>
    {error && <p className="nf-inline-warning" role="alert">{error}</p>}
    <div className="nf-table-wrap nf-config-table"><table>
      <thead><tr><th>对象</th><th>当前</th><th>上游最新</th><th>结论</th><th>操作</th></tr></thead>
      <tbody>
        <tr>
          <td>Zashboard 面板</td>
          <td>{panel?.installed ?? snapshot.dashboard.version ?? '未记录'}</td>
          <td>{panel?.available ?? (panel?.error ? '检查失败' : '尚未检查')}</td>
          <td>{panel?.update_available ? '有可用更新' : panel?.error ? '检查失败' : '已是最新'}</td>
          <td><div className="nf-desktop-inline">
            <button type="button" className="nf-button-secondary" disabled={disabled || !panel?.update_available} onClick={() => setConfirmPanel(true)}>更新面板</button>
            <button type="button" className="nf-button-secondary" disabled={disabled} onClick={check}>检查更新</button>
          </div></td>
        </tr>
        <tr>
          <td>macOS 应用</td>
          <td>{app?.installed ?? snapshot.core.identity?.version ?? '未记录'}</td>
          <td>{app?.available ?? (app?.error ? '检查失败' : '尚未检查')}</td>
          <td>{app?.installation_unknown ? '当前安装未记录，无法比较'
            : app?.update_available ? canInstallApp ? '有可用版本，可在此安装' : '有可用版本，需手动安装'
            : app?.error ? '检查失败' : '已是最新'}</td>
          <td><div className="nf-desktop-inline">
            {canInstallApp && <button type="button" className="nf-button-primary" disabled={disabled} onClick={() => setConfirmApp(true)}>安装更新</button>}
            {app?.url && <a className="nf-inline-link" href={app.url} target="_blank" rel="noreferrer">{canInstallApp ? '查看 Release' : '打开 Release'}</a>}
          </div></td>
        </tr>
      </tbody>
    </table></div>
    <p className="nf-management-note"><Info aria-hidden="true" />面板更新会校验上游资产的大小与 SHA-256 后才替换本机副本，正在运行的核心无需重启。
      应用更新只对 Developer ID 签名并已公证的分发构建开放：候选来自带 sha256 摘要的正式 Release，
新包还要通过 Apple 签名与公证验证，再由独立进程在应用退出后做单槽替换并重新打开；
      失败会恢复旧版本。{selfUpdate && selfUpdate !== 'available' ? ` ${selfUpdateNote[selfUpdate] ?? ''}` : ''}{checkedAt ? ` 最近检查：${checkedAt}。` : ''}</p>
    {confirmApp && <section className="nf-desktop-inline-note" role="alertdialog" aria-label="确认安装应用更新">
      <span>将安装 {app?.available}（当前 {app?.installed ?? '未记录'}）。应用会先停止代理并撤销网络接管，退出后替换并重新打开；替换失败会恢复当前版本。</span>
      <div className="nf-desktop-inline">
        <button type="button" className="nf-button-secondary" onClick={() => setConfirmApp(false)}>取消</button>
        <button type="button" className="nf-button-primary" disabled={disabled} onClick={installApp}>确认安装并重启</button>
      </div>
    </section>}
    {confirmPanel && <section className="nf-desktop-inline-note" role="alertdialog" aria-label="确认更新面板">
      <span>将从上游下载 {panel?.available} 并校验后替换本机面板副本（当前 {panel?.installed ?? '未记录'}）。</span>
      <div className="nf-desktop-inline">
        <button type="button" className="nf-button-secondary" onClick={() => setConfirmPanel(false)}>取消</button>
        <button type="button" className="nf-button-primary" disabled={disabled} onClick={install}>确认更新</button>
      </div>
    </section>}
  </section>;
}

export function CoreSection({ snapshot, client, run, disabled = false }: {
  snapshot: DesktopSnapshot; client?: DesktopNetFleetClient; run?: RunAction; disabled?: boolean;
}) {
  const core = snapshot.core;
  const identity = core.identity;
  const groups = [...new Set(core.rows.map((row) => row.group))];
  return <div className="nf-view-stack">
    {client && run && <UpdateSection snapshot={snapshot} client={client} run={run} disabled={disabled} />}
    <section className="nf-config-section">
      <div className="nf-config-section-heading">
        <h2>应用构建身份</h2>
        <p>本次安装的应用版本与源码身份；源码运行没有构建记录时显示未记录。</p>
      </div>
      {identity ? <div className="nf-policy-grid">
        <dl><dt>应用版本</dt><dd>{identity.version ? `${identity.version}${identity.release ? ` · 修订 ${identity.release}` : ''}` : '版本未记录'}</dd></dl>
        <dl><dt>渠道</dt><dd>{identity.channel || '未记录'}{identity.working_tree_dirty ? ' · 含未提交改动' : ''}</dd></dl>
        <dl><dt>源码提交</dt><dd title={identity.source_commit || undefined}>{short(identity.source_commit) || '未记录'}</dd></dl>
      </div> : <p className="nf-management-note">源码运行没有构建记录，安装包内的 <code>build.json</code> 会在这里显示版本、渠道和源码提交。</p>}
    </section>

    <section className="nf-config-section">
      <div className="nf-config-section-heading">
        <h2>运行组件</h2>
        <p>随本应用打包并实际执行的组件；核心运行版本在概览的“运行概况”中显示。</p>
      </div>
      <div className="nf-table-wrap nf-config-table"><table>
        <thead><tr><th>组件</th><th>版本</th><th>来源</th></tr></thead>
        <tbody>{core.components.map((item) => <tr key={item.id}>
          <td>{item.label}</td>
          <td title={item.version || undefined}>{short(item.version) || '版本未记录'}</td>
          <td>{componentSources[item.source] || item.source}</td>
        </tr>)}</tbody>
      </table></div>
    </section>

    <section className="nf-config-section">
      <div className="nf-config-section-heading">
        <h2>Mihomo 高级设置</h2>
        <p>本机平台交给代理核心的设置，只读呈现；接入方式在概览切换。Profile 声明值来自当前配置，平台接管值为本机强制或补齐的值。</p>
      </div>
      <div className="nf-table-wrap nf-config-table"><table>
        <thead><tr><th>项目</th><th>来源</th><th>交给核心</th><th>运行回读</th></tr></thead>
        <tbody>{groups.flatMap((group) => [
          <tr className="nf-core-group" key={`group-${group}`}><td colSpan={4}>{group}</td></tr>,
          ...core.rows.filter((row) => row.group === group).map((row) => <tr key={row.id}>
            <td>{row.label}</td>
            <td>{sourceLabels[row.source]}</td>
            <td>{value(row.configured, '核心默认')}{row.declared !== null && row.declared !== row.configured && <small>Profile 声明：{row.declared}</small>}</td>
            <td>{row.running !== null ? row.running : core.running ? '核心未提供读取' : '未运行'}</td>
          </tr>),
        ])}</tbody>
      </table></div>
      <p className="nf-management-note"><Info aria-hidden="true" />{core.overlay
        ? 'TUN 特权会话正在接管：DNS 劫持、嗅探默认值和 TUN 会话参数由该会话写入，退出 TUN 后按剩余设置运行。'
        : core.mode === 'tun'
          ? 'TUN 接入方式已选择但当前没有特权会话；会话参数在接管成功后显示。'
          : '显式代理与系统代理都由本应用的核心进程执行，上表即当前生效值。'}{core.profile ? ` 当前配置：${core.profile}。` : ''}</p>
    </section>
  </div>;
}
