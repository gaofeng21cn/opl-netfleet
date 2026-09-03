import React, { useState } from 'react';
import { CheckCircle2, ClipboardCheck, Eye, LockKeyhole, RotateCcw, Save, WandSparkles } from 'lucide-react';
import type { ConfigDraft, ConfigSectionId } from './model';
import { configSummary, validateConfigDraft } from './model';
import {
  AutomationSection,
  ExitsSection,
  FoundationSection,
  ProvidersSection,
  RegionsSection,
  SafetySection,
  sectionMeta,
} from './ConfigSections';
import { SetupWizard } from './SetupWizard';
import type { StatusSnapshot } from '../types';

interface ConfigViewProps {
  draft: ConfigDraft;
  savedDraft: ConfigDraft;
  status: StatusSnapshot;
  onChange(next: ConfigDraft): void;
  onSave(next: ConfigDraft): void;
}

export function ConfigView({ draft, savedDraft, status, onChange, onSave }: ConfigViewProps) {
  const [section, setSection] = useState<ConfigSectionId>('foundation');
  const [wizard, setWizard] = useState(false);
  const [review, setReview] = useState(false);
  const [validation, setValidation] = useState<string[] | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const dirty = JSON.stringify(draft) !== JSON.stringify(savedDraft);
  const summary = configSummary(draft);

  const change = (next: ConfigDraft) => {
    setValidation(null);
    setMessage(null);
    onChange(next);
  };

  const validate = () => {
    const errors = validateConfigDraft(draft);
    setValidation(errors);
    setMessage(errors.length === 0 ? '配置校验通过，可以保存本地预览。' : null);
    return errors;
  };

  const save = () => {
    if (validate().length > 0) return;
    onSave(draft);
    setMessage(status.active ? '本地预览已应用；设备运行状态没有改变。' : '本地配置预览已保存；设备没有启用。');
  };

  const sectionProps = { draft, status, onChange: change };
  const content = {
    foundation: <FoundationSection {...sectionProps} />,
    providers: <ProvidersSection {...sectionProps} />,
    regions: <RegionsSection {...sectionProps} />,
    exits: <ExitsSection {...sectionProps} />,
    automation: <AutomationSection {...sectionProps} />,
    safety: <SafetySection {...sectionProps} />,
  }[section];

  if (wizard) return <SetupWizard
    draft={draft}
    status={status}
    onChange={change}
    onCancel={() => setWizard(false)}
    onFinish={(next) => {
      onSave(next);
      setWizard(false);
      setMessage('首次设置流程已完成本地预览；设备没有发生任何改变。');
    }}
  />;

  return <div className="nf-config-view">
    <section className="nf-config-preview-note">
      <LockKeyhole aria-hidden="true" />
      <div><strong>本地配置交互预览</strong><span>资源名称来自当前数据源；编辑、校验和应用都不会写入设备。</span></div>
      <button type="button" onClick={() => setWizard(true)}><WandSparkles aria-hidden="true" />预览首次设置向导</button>
    </section>

    <div className="nf-config-layout">
      <nav className="nf-config-tabs" aria-label="配置分类">
        {sectionMeta.map((item) => {
          const Icon = item.icon;
          return <button className={section === item.id ? 'is-active' : ''} type="button" key={item.id} onClick={() => setSection(item.id)}><Icon aria-hidden="true" /><span>{item.label}</span></button>;
        })}
      </nav>
      <div className="nf-config-content">{content}</div>
    </div>

    {review && <section className="nf-config-review">
      <div className="nf-config-section-heading"><h2>配置摘要</h2><p>这里只展示产品语义，不展示底层配置字段。</p></div>
      <dl><div><dt>策略基础</dt><dd>{draft.policySource === 'bundle' ? 'NetFleet 内置基础策略' : '沿用当前 Nikki 配置'}</dd></div><div><dt>参与机场</dt><dd>{summary.providerCount} 个，其中主用 {summary.primaryCount}、备用 {summary.reserveCount}</dd></div><div><dt>地区</dt><dd>{summary.automaticRegionCount} 个参与自动选优</dd></div><div><dt>出口</dt><dd>{summary.capabilityCount} 个已启用</dd></div><div><dt>周期选优</dt><dd>{draft.automation.enabled ? `${draft.automation.selectionIntervalSeconds / 60} 分钟` : '已关闭'}</dd></div><div><dt>恢复配置</dt><dd>{draft.recoveryProfile}</dd></div></dl>
    </section>}

    {validation && <div className={`nf-config-validation ${validation.length ? 'is-error' : 'is-success'}`} role="status">
      {validation.length ? <><strong>发现 {validation.length} 个问题</strong><ul>{validation.map((error) => <li key={error}>{error}</li>)}</ul></> : <><CheckCircle2 aria-hidden="true" /><strong>配置校验通过</strong></>}
    </div>}
    {message && <div className="nf-config-message" role="status"><CheckCircle2 aria-hidden="true" />{message}</div>}

    <div className="nf-config-actions">
      <span>{dirty ? '有尚未保存的本地更改' : '本地预览与已保存状态一致'}</span>
      <div>
        <button type="button" disabled={!dirty} onClick={() => { onChange(savedDraft); setValidation(null); setMessage(null); }}><RotateCcw aria-hidden="true" />放弃更改</button>
        <button type="button" onClick={validate}><ClipboardCheck aria-hidden="true" />校验配置</button>
        <button type="button" onClick={() => setReview(!review)}><Eye aria-hidden="true" />{review ? '收起摘要' : '查看变更'}</button>
        <button className="nf-button-primary" type="button" disabled={!dirty} onClick={save}><Save aria-hidden="true" />{status.active ? '应用本地预览' : '保存本地预览'}</button>
      </div>
    </div>
  </div>;
}
