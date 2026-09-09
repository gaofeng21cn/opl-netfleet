export interface PluginDefinition {
  id: string;
  revision: string;
  label?: string;
  enabled?: boolean;
  available?: boolean;
  runtime?: string;
  state?: string;
  instance?: string;
  ui?: Array<{ id: string; title: string; module: string; navigation?: "primary" | "plugin" }>;
  configuration?: { read: string; write: string };
}
export interface PluginsSnapshot { plugins: PluginDefinition[] }
export interface PluginPage { id: `plugin:${string}:${string}`; title: string; plugin: PluginDefinition; page: NonNullable<PluginDefinition['ui']>[number] }
export interface PluginRequest { id: string; action: string; params: Record<string, unknown>; revision: string; instance?: string; confirm?: true }
export interface PluginApi {
  pluginRead(request: PluginRequest): Promise<unknown>;
  pluginCall(request: PluginRequest): Promise<unknown>;
}
export interface PluginScope {
  signal: AbortSignal;
  effect(cleanup: () => unknown): () => Promise<void>;
  on(name: string, callback: (value: unknown) => void): () => Promise<void>;
  emit(name: string, value?: unknown): void;
  scope(): PluginScope;
  timeout(callback: () => void, delay: number): () => Promise<void>;
  interval(callback: () => void, delay: number): () => Promise<void>;
  dispose(): Promise<void>;
}
export interface PluginContext {
  container: HTMLElement;
  signal: AbortSignal;
  scope: PluginScope;
  readOnly: boolean;
  navigate(id: string, state?: Record<string, unknown>): void;
  state?: Record<string, unknown>;
  api: { read(action: string, params?: Record<string, unknown>): Promise<unknown>; call(action: string, params?: Record<string, unknown>): Promise<unknown> };
  configuration: { read(params?: Record<string, unknown>): Promise<unknown>; write(params?: Record<string, unknown>): Promise<unknown> } | null;
}
export interface PluginModule { mount(context: PluginContext): void | (() => unknown) | Promise<void | (() => unknown)> }
export function pluginPages(snapshot: PluginsSnapshot | null): PluginPage[];
export function pluginNavigation(pages: PluginPage[]): { primary: PluginPage[]; groups: Array<{ id: string; title: string; instance?: string; pages: PluginPage[] }>; defaultId: string; directoryId: string };
export function resourceUrl(page: PluginPage): string;
export function createScope(events?: Map<string, Set<(value: unknown) => void>>, report?: (error: unknown) => void): PluginScope;
export function createPageHost(options: { api: PluginApi; readOnly?: boolean | (() => boolean); loadModule?: (url: string) => Promise<PluginModule>; onError?: (error: unknown) => void; navigate?: (id: string, state?: Record<string, unknown>) => void }): {
  dispose(): Promise<void>;
  show(page: PluginPage, container: HTMLElement, state?: Record<string, unknown>): Promise<void>;
};

export const pluginHostStyles: string;

export function pageHash(id: string): string;
export function pageFromHash(hash: string, pages: PluginPage[]): string;
