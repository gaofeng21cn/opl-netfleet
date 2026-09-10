import { createRoot } from 'react-dom/client';
import { DesktopNetFleetClient } from './client';
import { DesktopApp } from './DesktopApp';
import '../styles.css';
import './desktop.css';

const url = new URL(window.location.href);
const token = url.searchParams.get('token');
url.searchParams.delete('token');
history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
const root = createRoot(document.getElementById('root')!);
if (!token) {
  root.render(<main className="nf-app nf-desktop"><section className="nf-main"><h1>本机会话不可用</h1><p role="alert">请退出并重新打开 NetFleet，以建立经过认证的本机会话。</p></section></main>);
} else root.render(<DesktopApp client={new DesktopNetFleetClient(token)} />);
