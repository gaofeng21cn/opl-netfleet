import { useRef, useState } from 'react';
import { Download, FilePlus2, Pencil, RefreshCw, Save, Trash2, Upload, X } from 'lucide-react';
import type { NetFleetClient } from '../types';
import { useManagementRead } from './useManagementRead';

interface ProfileDraft { id: string; content: string }
const localOnly = '本机预览只读；请在设备 LuCI 中操作';
const fileSize = (size: number) => size < 1024 ? `${size} B` : `${(size / 1024).toFixed(1)} KB`;

export function FilesSection({ client }: { client?: NetFleetClient }) {
  const { data, loading, error, refresh } = useManagementRead(client, 'maintenance');
  const [drafts, setDrafts] = useState<ProfileDraft[]>([]);
  const [editor, setEditor] = useState<ProfileDraft | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [restore, setRestore] = useState<{ name: string; size: number; createdAt: number | null; sections: number; files: number } | null>(null);
  const profileInput = useRef<HTMLInputElement>(null);
  const backupInput = useRef<HTMLInputElement>(null);
  const supported = Boolean(data?.supported);

  const importProfile = async (file?: File) => {
    if (!file) return;
    setFileError(null); setMessage(null);
    if (!/\.(json|ya?ml)$/i.test(file.name) || file.size > 8 * 1024 * 1024) {
      setFileError('请选择不超过 8 MB 的 JSON 或 YAML 配置文件。'); return;
    }
    try { setEditor({ id: file.name, content: await file.text() }); }
    catch { setFileError('无法读取本地配置文件。'); }
  };

  const keepDraft = () => {
    if (!editor) return;
    setFileError(null);
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]*\.(json|yaml|yml)$/.test(editor.id) || editor.id.length > 120 || editor.id.includes('..') || editor.id === 'OPL-NetFleet.json' || !editor.content.trim() || new Blob([editor.content]).size > 8 * 1024 * 1024) {
      setFileError('请输入有效配置文件名和内容。'); return;
    }
    if (data?.profiles.some(item => item.id === editor.id && item.referenced)) {
      setFileError('这份文件正在被引用；请使用另一个文件名。'); return;
    }
    if (editor.id.endsWith('.json')) {
      try { JSON.parse(editor.content); }
      catch { setFileError('JSON 语法无效。'); return; }
    }
    setDrafts([...drafts.filter(item => item.id !== editor.id), editor]);
    setEditor(null);
    setMessage('配置文件仅保留在本页内存中；未提交到设备或通过核心校验。');
  };

  const inspectBackup = async (file?: File) => {
    if (!file) return;
    setFileError(null); setRestore(null);
    if (file.size > 32 * 1024 * 1024) { setFileError('备份文件不能超过 32 MB。'); return; }
    try {
      const parsed = JSON.parse(await file.text()) as { format?: unknown; created_at?: unknown; sections?: unknown; files?: unknown };
      if (parsed.format !== 'netfleet-backup-v1' || !Array.isArray(parsed.sections) || !Array.isArray(parsed.files)) throw new Error();
      setRestore({ name: file.name, size: file.size, createdAt: typeof parsed.created_at === 'number' ? parsed.created_at : null, sections: parsed.sections.length, files: parsed.files.length });
    } catch { setFileError('文件不是可识别的 NetFleet 备份。'); }
  };

  return <section className="nf-config-section nf-management">
    <div className="nf-config-section-heading nf-section-heading"><h2>配置文件与备份</h2><button type="button" disabled={loading || !client} onClick={() => void refresh()}><RefreshCw aria-hidden="true" className={loading ? 'is-spinning' : ''} />重新读取</button></div>
    {error && <div className="nf-alert" role="alert">{error}</div>}
    {!data && <p className="nf-management-note">{loading ? '正在读取配置文件列表…' : '当前数据源未提供配置维护信息。'}</p>}
    {data && !supported && <p className="nf-inline-warning">当前配置文件由 Nikki 管理；迁移到 NetFleet 原生后端后可在这里维护。</p>}
    {data?.supported && <>
      <section className="nf-management-subsection">
        <div className="nf-section-heading"><h3>本地配置文件</h3><div className="nf-management-buttons"><button type="button" onClick={() => { setEditor({ id: '', content: '' }); setFileError(null); }}><FilePlus2 aria-hidden="true" />新建草稿</button><button type="button" onClick={() => profileInput.current?.click()}><Upload aria-hidden="true" />导入本地文件</button></div></div>
        <input ref={profileInput} type="file" accept=".json,.yaml,.yml" hidden onChange={event => { void importProfile(event.target.files?.[0]); event.target.value = ''; }} />
        <div className="nf-table-wrap nf-management-table"><table><thead><tr><th>文件</th><th>格式</th><th>大小</th><th>修改时间</th><th>状态</th><th>操作</th></tr></thead><tbody>
          {data.profiles.map(profile => <tr key={profile.id}><td><strong>{profile.id}</strong></td><td>{profile.format.toUpperCase()}</td><td>{fileSize(profile.size_bytes)}</td><td>{profile.modified_at ? new Date(profile.modified_at * 1000).toLocaleString() : '未提供'}</td><td>{profile.referenced ? '使用中' : '未引用'}</td><td><div className="nf-management-buttons"><button className="nf-icon-button" type="button" disabled title={localOnly} aria-label={`下载 ${profile.id}`}><Download aria-hidden="true" /></button><button className="nf-icon-button" type="button" disabled title={profile.editable ? localOnly : '正在使用的配置不能直接编辑'} aria-label={`编辑 ${profile.id}`}><Pencil aria-hidden="true" /></button><button className="nf-icon-button" type="button" disabled title={profile.referenced ? '正在使用的配置不能删除' : localOnly} aria-label={`删除 ${profile.id}`}><Trash2 aria-hidden="true" /></button></div></td></tr>)}
          {drafts.map(draft => <tr key={`draft:${draft.id}`}><td><strong>{draft.id}</strong></td><td>{draft.id.split('.').pop()?.toUpperCase()}</td><td>{fileSize(new Blob([draft.content]).size)}</td><td>未写入设备</td><td>本地草稿</td><td><div className="nf-management-buttons"><button className="nf-icon-button" type="button" title="编辑本地草稿" aria-label={`编辑草稿 ${draft.id}`} onClick={() => setEditor({ ...draft })}><Pencil aria-hidden="true" /></button><button className="nf-icon-button" type="button" title="丢弃本地草稿" aria-label={`丢弃草稿 ${draft.id}`} onClick={() => setDrafts(drafts.filter(item => item.id !== draft.id))}><Trash2 aria-hidden="true" /></button></div></td></tr>)}
          {!data.profiles.length && !drafts.length && <tr><td colSpan={6}>没有本地配置文件</td></tr>}
        </tbody></table></div>
        {editor && <div className="nf-profile-editor"><div className="nf-section-heading"><h3>本地文件草稿</h3><button className="nf-icon-button" type="button" title="关闭编辑" aria-label="关闭配置文件编辑" onClick={() => setEditor(null)}><X aria-hidden="true" /></button></div><label>文件名<input value={editor.id} placeholder="custom.json" onChange={event => setEditor({ ...editor, id: event.target.value })} /></label><label>配置内容<textarea rows={14} value={editor.content} spellCheck={false} autoComplete="off" onChange={event => setEditor({ ...editor, content: event.target.value })} /></label><div className="nf-management-buttons"><button type="button" onClick={() => setEditor(null)}>取消</button><button type="button" onClick={keepDraft}><Save aria-hidden="true" />保留本地草稿</button></div></div>}
      </section>
      <section className="nf-management-subsection"><h3>NetFleet 备份</h3><p className="nf-management-note">包含 NetFleet 配置、订阅和本地配置文件，不包含 OpenWrt 系统配置。备份可能含订阅凭据，请妥善保管。</p><div className="nf-management-buttons"><button type="button" disabled title={localOnly}><Download aria-hidden="true" />导出设备备份</button><button type="button" onClick={() => backupInput.current?.click()}><Upload aria-hidden="true" />选择恢复文件</button></div>
        <input ref={backupInput} type="file" accept=".json" hidden onChange={event => { void inspectBackup(event.target.files?.[0]); event.target.value = ''; }} />
        {restore && <div className="nf-backup-review"><dl><div><dt>恢复文件</dt><dd>{restore.name}</dd></div><div><dt>文件大小</dt><dd>{fileSize(restore.size)}</dd></div><div><dt>创建时间</dt><dd>{restore.createdAt ? new Date(restore.createdAt * 1000).toLocaleString() : '未提供'}</dd></div><div><dt>备份内容</dt><dd>{restore.sections} 组配置 / {restore.files} 个文件</dd></div><div><dt>检查状态</dt><dd>格式已识别，尚未执行设备校验</dd></div></dl><div className="nf-management-buttons"><button type="button" onClick={() => setRestore(null)}>取消</button><button type="button" disabled title={localOnly}>恢复到设备</button></div></div>}
      </section>
    </>}
    {fileError && <div className="nf-alert" role="alert">{fileError}</div>}
    {message && <div className="nf-config-message" role="status">{message}</div>}
  </section>;
}
