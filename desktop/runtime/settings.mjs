// 本机核心设置的只读投影。每一行都取三个真实来源：Profile 声明值、平台交给核心的
// 投影值（CoreOwner.projectProfile）、特权 TUN 会话实际应用的覆写（helper overlay），
// 以及运行中核心的 controller 回读。这里不重新实现任何映射，只选择展示哪些字段。
const display = value => {
  if (value === null || value === undefined) return null;
  if (typeof value === 'boolean') return value ? '开启' : '关闭';
  if (Array.isArray(value)) return value.length ? value.map(display).filter(Boolean).join('、') : null;
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
};

const read = (source, keys) => {
  let node = source;
  for (const key of keys) {
    if (!node || typeof node !== 'object') return undefined;
    node = node[key];
  }
  return node;
};

const same = (left, right) => JSON.stringify(left ?? null) === JSON.stringify(right ?? null);

const fields = [
  { id: 'dns.enable', group: 'DNS', label: 'DNS 接管', keys: ['dns', 'enable'], overlay: overlay => overlay['dns-enable'] },
  { id: 'dns.listen', group: 'DNS', label: '本机 DNS 监听', keys: ['dns', 'listen'],
    overlay: overlay => overlay['dns-listen-removed'] === true ? '由 TUN 会话移除（DNS 劫持到内核）' : undefined },
  { id: 'dns.enhanced-mode', group: 'DNS', label: '解析模式', keys: ['dns', 'enhanced-mode'] },
  { id: 'dns.nameserver', group: 'DNS', label: 'DNS 服务器', keys: ['dns', 'nameserver'] },
  { id: 'sniffer.enable', group: '嗅探', label: '协议嗅探', keys: ['sniffer', 'enable'],
    overlay: overlay => overlay.injected?.includes('sniffer') ? read(overlay.sniffer, ['enable']) ?? true : undefined },
  { id: 'sniffer.sniff', group: '嗅探', label: '嗅探协议与端口', keys: ['sniffer', 'sniff'],
    overlay: overlay => overlay.injected?.includes('sniffer') ? read(overlay, ['sniffer', 'sniff']) : undefined },
  { id: 'unified-delay', group: '传输', label: '统一延迟测量', keys: ['unified-delay'], running: running => running['unified-delay'] },
  { id: 'ipv6', group: '传输', label: 'IPv6', keys: ['ipv6'], running: running => running.ipv6 },
  { id: 'tcp-concurrent', group: '传输', label: 'TCP 并发连接', keys: ['tcp-concurrent'], running: running => running['tcp-concurrent'] },
  { id: 'mixed-port', group: '核心', label: '本机混合代理端口', keys: ['mixed-port'], running: running => running['mixed-port'] },
  { id: 'allow-lan', group: '核心', label: '局域网访问', keys: ['allow-lan'], running: running => running['allow-lan'] },
  { id: 'log-level', group: '核心', label: '核心日志级别', keys: ['log-level'], running: running => running['log-level'] },
  { id: 'find-process-mode', group: '核心', label: '进程匹配', keys: ['find-process-mode'], running: running => running['find-process-mode'] },
];

// TUN 会话参数只在特权组件报告本次会话时展示；没有会话就不猜测实际值。
const tunFields = [
  { id: 'tun.device', group: 'TUN 会话', label: '虚拟网卡', keys: ['device'], profileKeys: ['tun', 'device'], running: running => read(running, ['tun', 'device']) },
  { id: 'tun.stack', group: 'TUN 会话', label: '协议栈', keys: ['stack'], profileKeys: ['tun', 'stack'], running: running => read(running, ['tun', 'stack']) },
  { id: 'tun.auto-route', group: 'TUN 会话', label: '自动路由', keys: ['auto-route'], profileKeys: ['tun', 'auto-route'], running: running => read(running, ['tun', 'auto-route']) },
  { id: 'tun.dns-hijack', group: 'TUN 会话', label: 'DNS 劫持', keys: ['dns-hijack'], profileKeys: ['tun', 'dns-hijack'], running: running => read(running, ['tun', 'dns-hijack']) },
];

export function coreSettingRows({ profile = null, projected = null, running = null, overlay = null } = {}) {
  const session = overlay && typeof overlay === 'object' ? overlay : null;
  const sources = session?.tun ? [...fields, ...tunFields] : fields;
  return sources.map(field => {
    const declared = read(profile, field.profileKeys || field.keys);
    const projectedValue = field.group === 'TUN 会话' ? read(session?.tun, field.keys) : read(projected, field.keys);
    const applied = field.overlay && session ? field.overlay(session) : undefined;
    const overridden = applied !== undefined || (projectedValue !== undefined && !same(projectedValue, declared));
    const effective = applied !== undefined ? applied : projectedValue !== undefined ? projectedValue : declared;
    const source = overridden ? 'platform' : declared !== undefined ? 'profile' : 'core_default';
    const runtime = running && field.running ? field.running(running) : undefined;
    return { id: field.id, group: field.group, label: field.label, source,
      configured: display(effective), declared: display(declared), running: display(runtime) };
  });
}
