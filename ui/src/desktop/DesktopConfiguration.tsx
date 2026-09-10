import { useEffect, useState } from 'react';
import { Code2, FileInput } from 'lucide-react';
import { AutomationSection, ExitsSection, ProvidersSection, RegionsSection, RoutingSection, SafetySection, sectionMeta } from '../config/ConfigSections';
import { configChanges, validateConfigDraft, type ConfigDraft } from '../config/model';
import type { DesktopSnapshot } from './types';
import type { DesktopNetFleetClient } from './client';
import { toDesktopDraft, desktopConfigRequest } from './policy';
import type { DeviceConfigSnapshot } from '../types';
import { Configuration, type RunAction } from './panels';

const structuredSections = ['providers', 'regions', 'exits', 'routing', 'automation', 'safety'];
export function DesktopConfiguration({ snapshot, disabled, client, run, onManageSubscriptions }: { snapshot: DesktopSnapshot; disabled: boolean; client: DesktopNetFleetClient; run: RunAction; onManageSubscriptions(): void }) {
  const [section, setSection] = useState('profile');
  const [draft, setDraft] = useState<ConfigDraft | null>(null);
  const [saved, setSaved] = useState<ConfigDraft | null>(null);
  const [original, setOriginal] = useState<DeviceConfigSnapshot | null>(null);
  const [advancedDirty, setAdvancedDirty] = useState(false);
  const [validation, setValidation] = useState<string[]>([]);
  const [review, setReview] = useState(false);
  const dirty = Boolean(draft && saved && JSON.stringify(draft) !== JSON.stringify(saved));
  useEffect(() => {
    if (dirty || !snapshot.config || !snapshot.status) return;
    const value = toDesktopDraft(snapshot);
    setDraft(value); setSaved(value); setOriginal(snapshot.config);
  }, [snapshot.config, snapshot.status, dirty]);
  const change = (next: ConfigDraft) => { setDraft(next); setValidation([]); };
  const props = draft && snapshot.status ? { draft, status: snapshot.status, onChange: change, onManageSubscriptions } : null;
  const content = props ? {
    providers: <ProvidersSection {...props} />,
    regions: <RegionsSection {...props} />,
    exits: <ExitsSection {...props} />,
    routing: <RoutingSection {...props} />,
    automation: <AutomationSection {...props} />,
    safety: <SafetySection {...props} />,
  }[section] : null;
  const save = () => {
    if (!draft || !original) return;
    const errors = validateConfigDraft(draft);
    setValidation(errors);
    if (errors.length) return;
    let request: Record<string, unknown>;
    try { request = desktopConfigRequest(original, draft); }
    catch (reason) { setValidation([reason instanceof Error ? reason.message : String(reason)]); return; }
    void run('保存业务配置', () => client.action('config-save', { request })).then(ok => { if (ok) { setSaved(draft); setReview(false); } });
  };
  return <div className="nf-config-view">
    <div className="nf-config-layout">
      <nav className="nf-config-tabs" aria-label="配置分类">
        <button type="button" className={section === 'profile' ? 'is-active' : ''} onClick={() => setSection('profile')}><FileInput aria-hidden="true" /><span>基础配置</span></button>
        {sectionMeta.filter(item => structuredSections.includes(item.id)).map(item => { const Icon = item.icon; return <button type="button" key={item.id} className={section === item.id ? 'is-active' : ''} onClick={() => setSection(item.id)}><Icon aria-hidden="true" /><span>{item.label}</span></button>; })}
        <button type="button" className={section === 'advanced' ? 'is-active' : ''} onClick={() => setSection('advanced')}><Code2 aria-hidden="true" /><span>高级 JSON</span></button>
      </nav>
      <div className="nf-config-content">
        {snapshot.configError && <p className="nf-inline-warning" role="alert">{snapshot.configError}</p>}
        <div hidden={section !== 'profile'}><Configuration section="profile" snapshot={snapshot} disabled={disabled || dirty || advancedDirty} client={client} run={run} /></div>
        <div hidden={section !== 'advanced'}><Configuration section="advanced" snapshot={snapshot} disabled={disabled || dirty} client={client} run={run} onDirtyChange={setAdvancedDirty} /></div>
        {structuredSections.includes(section) && <>{props ? <fieldset className="nf-desktop-fieldset" disabled={disabled || advancedDirty}>{content}</fieldset> : <section className="nf-config-section"><h2>尚未生成业务配置</h2><p className="nf-management-note">先在“机场”添加订阅，自动生成内置策略、地区与双出口。</p><button type="button" className="nf-button-primary" disabled={disabled || !snapshot.runtime.configured} onClick={() => void run('生成初始业务配置', () => client.action('compile'))}>校验并编译</button></section>}</>}
        {(dirty || advancedDirty) && <p className="nf-management-note">{advancedDirty ? '高级 JSON 有未保存修改。保存后可继续编辑表单。' : '表单有未保存修改。保存或放弃后可导入配置或编辑高级 JSON。'}</p>}
      </div>
    </div>
    {structuredSections.includes(section) && draft && saved && <>
      {validation.length > 0 && <div className="nf-config-validation is-error" role="alert"><ul>{validation.map(item => <li key={item}>{item}</li>)}</ul></div>}
      {review && <section className="nf-config-review"><h2>变更预览</h2>{dirty ? <ul>{configChanges(saved, draft).map(item => <li key={item}>{item}</li>)}</ul> : <p>没有尚未保存的更改。</p>}</section>}
      {snapshot.runtime.mode === 'netfleet' && <div className="nf-management-note">退出增强后可以保存配置，草稿会保留。<button type="button" className="nf-button-secondary" disabled={disabled} onClick={() => void run('退出增强并保留原生代理', () => client.disable())}>退出增强</button></div>}
      <div className="nf-config-actions"><span>{dirty ? '有尚未保存的更改' : '与本机已保存策略一致'}</span><div><button type="button" disabled={disabled || !dirty} onClick={() => { setDraft(saved); setValidation([]); }}>放弃更改</button><button type="button" onClick={() => { setValidation(validateConfigDraft(draft)); setReview(!review); }}>校验与变更</button><button type="button" className="nf-button-primary" disabled={disabled || !dirty || advancedDirty || snapshot.runtime.mode === 'netfleet'} onClick={save}>保存配置</button><button type="button" disabled={disabled || dirty || advancedDirty} onClick={() => void run('校验并编译', () => client.action('compile'))}>编译已保存配置</button></div></div>
    </>}
  </div>;
}
