import React from 'react';
import { ArrowLeft, ArrowRight, Check, X } from 'lucide-react';
import type { ConfigDraft } from './model';
import { configSummary, validateConfigDraft } from './model';
import {
  AutomationSection,
  ExitsSection,
  FoundationSection,
  ProvidersSection,
  RegionsSection,
  RoutingSection,
  SafetySection,
} from './ConfigSections';
import type { StatusSnapshot } from '../types';

const steps = ['环境与恢复', '机场', '地区', '出口', '业务规则', '运行与安全'];

interface SetupWizardProps {
  draft: ConfigDraft;
  status: StatusSnapshot;
  onChange(next: ConfigDraft): void;
  onFinish(next: ConfigDraft): void;
  onCancel(): void;
}

export function SetupWizard({ draft, status, onChange, onFinish, onCancel }: SetupWizardProps) {
  const [step, setStep] = React.useState(0);
  const [errors, setErrors] = React.useState<string[]>([]);
  const summary = configSummary(draft);

  const finish = () => {
    const nextErrors = validateConfigDraft(draft);
    setErrors(nextErrors);
    if (nextErrors.length === 0) onFinish(draft);
  };

  return <div className="nf-setup-wizard">
    <div className="nf-wizard-heading">
      <div><h2>首次设置 NetFleet</h2><p>使用当前设备数据完成配置预览；所有步骤只保存在本机浏览器。</p></div>
      <button className="nf-icon-button" type="button" aria-label="退出首次设置" onClick={onCancel}><X aria-hidden="true" /></button>
    </div>
    <ol className="nf-wizard-steps">
      {steps.map((label, index) => <li className={index === step ? 'is-active' : index < step ? 'is-complete' : ''} key={label}>
        <button type="button" onClick={() => setStep(index)} aria-current={index === step ? 'step' : undefined}>
          <span>{index < step ? <Check aria-hidden="true" /> : index + 1}</span><strong>{label}</strong>
        </button>
      </li>)}
    </ol>

    <div className="nf-wizard-content">
      {step === 0 && <FoundationSection draft={draft} status={status} onChange={onChange} />}
      {step === 1 && <ProvidersSection draft={draft} status={status} onChange={onChange} />}
      {step === 2 && <RegionsSection draft={draft} status={status} onChange={onChange} />}
      {step === 3 && <ExitsSection draft={draft} status={status} onChange={onChange} />}
      {step === 4 && <RoutingSection draft={draft} status={status} onChange={onChange} />}
      {step === 5 && <>
        <AutomationSection draft={draft} status={status} onChange={onChange} />
        <SafetySection draft={draft} status={status} onChange={onChange} />
        <section className="nf-wizard-review">
          <h3>启用前摘要</h3>
          <dl><div><dt>参与机场</dt><dd>{summary.providerCount} 个</dd></div><div><dt>主用 / 备用</dt><dd>{summary.primaryCount} / {summary.reserveCount}</dd></div><div><dt>自动地区</dt><dd>{summary.automaticRegionCount} 个</dd></div><div><dt>出口能力</dt><dd>{summary.capabilityCount} 个</dd></div></dl>
          <p>完成后只更新本地配置预览，不会生成设备配置，也不会启用 NetFleet。</p>
        </section>
      </>}
    </div>

    {errors.length > 0 && <div className="nf-config-validation is-error" role="alert"><strong>配置还不能完成</strong><ul>{errors.map((error) => <li key={error}>{error}</li>)}</ul></div>}
    <div className="nf-wizard-actions">
      <button type="button" onClick={step === 0 ? onCancel : () => setStep(step - 1)}><ArrowLeft aria-hidden="true" />{step === 0 ? '退出向导' : '上一步'}</button>
      {step < steps.length - 1
        ? <button className="nf-button-primary" type="button" onClick={() => { setErrors([]); setStep(step + 1); }}>下一步<ArrowRight aria-hidden="true" /></button>
        : <button className="nf-button-primary" type="button" onClick={finish}><Check aria-hidden="true" />完成首次设置预览</button>}
    </div>
  </div>;
}
