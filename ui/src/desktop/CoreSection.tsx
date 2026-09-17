import { Info } from 'lucide-react';
import type { DesktopSnapshot, CoreSettingRow } from './types';

// 只读投影：值来自 Mac 平台交给核心的配置、特权 TUN 会话实际应用的覆写、
// Profile 声明和运行中核心回读；页面不重新解释映射，也提交不了写入。
const sourceLabels: Record<CoreSettingRow['source'], string> = {
  platform: '平台接管', profile: 'Profile 声明', core_default: '核心默认',
};
const componentSources: Record<string, string> = { running: '运行回读', runtime: '本机回读', package: '随包版本' };
const short = (value: string | null) => value && /^[0-9a-f]{40}$/.test(value) ? value.slice(0, 8) : value;
const value = (input: string | null, fallback: string) => input ?? fallback;

export function CoreSection({ snapshot }: { snapshot: DesktopSnapshot }) {
  const core = snapshot.core;
  const identity = core.identity;
  const groups = [...new Set(core.rows.map((row) => row.group))];
  return <div className="nf-view-stack">
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
