export async function mount(context) {
  const { container, configuration, signal, scope } = context;
  const document = container.ownerDocument;
  const style = document.createElement("link");
  style.rel = "stylesheet";
  style.href = new URL("./style.css", import.meta.url).href;
  container.append(style);
  scope.effect(() => style.remove());

  const form = document.createElement("form");
  form.className = "netfleet-workspace-note";
  form.innerHTML = `
    <div class="note-toolbar">
      <h2>Workspace note</h2>
      <button type="button" data-refresh title="Reload note" aria-label="Reload note">&#8635;</button>
    </div>
    <label>Title<input name="title" type="text" maxlength="120" required></label>
    <label>Note<textarea name="text" rows="9" maxlength="8192"></textarea></label>
    <div class="note-actions">
      <button type="submit">Save</button>
      <output role="status" aria-live="polite"></output>
    </div>`;
  container.append(form);
  scope.effect(() => form.remove());

  const title = form.elements.namedItem("title");
  const text = form.elements.namedItem("text");
  const save = form.querySelector('button[type="submit"]');
  const refresh = form.querySelector("[data-refresh]");
  const status = form.querySelector("output");
  let current = null;
  let busy = false;
  const dirty = () => current && (title.value !== current.title || text.value !== current.text);
  const update = () => {
    save.disabled = context.readOnly || busy || !dirty() || !title.value.trim();
    refresh.disabled = busy;
    title.disabled = busy || !current;
    text.disabled = busy || !current;
    title.readOnly = !!context.readOnly;
    text.readOnly = !!context.readOnly;
  };
  const show = value => {
    current = value;
    title.value = value.title;
    text.value = value.text;
  };
  const describe = error => {
    const message = error?.message ?? String(error);
    if (message.includes("configuration_conflict")) return "The note changed. Reload to review the latest version.";
    if (message.includes("not_configured")) return "Note storage is not configured.";
    return message;
  };
  const read = async () => {
    busy = true;
    status.textContent = "Loading...";
    update();
    try {
      const value = await configuration.read();
      if (signal.aborted) return;
      show(value);
      status.textContent = "";
    } catch (error) {
      if (!signal.aborted) status.textContent = describe(error);
    } finally {
      if (!signal.aborted) { busy = false; update(); }
    }
  };

  form.addEventListener("input", () => { status.textContent = ""; update(); }, { signal });
  refresh.addEventListener("click", () => {
    if (!dirty() || document.defaultView.confirm("Discard unsaved changes?")) read();
  }, { signal });
  form.addEventListener("submit", async event => {
    event.preventDefault();
    if (context.readOnly || busy || !dirty() || !title.value.trim()) return;
    const candidate = { title: title.value, text: text.value, generation: current.generation };
    busy = true;
    status.textContent = "Saving...";
    update();
    try {
      const value = await configuration.write(candidate);
      if (signal.aborted) return;
      show(value);
      status.textContent = "Saved";
    } catch (error) {
      if (!signal.aborted) status.textContent = describe(error);
    } finally {
      if (!signal.aborted) { busy = false; update(); }
    }
  }, { signal });
  await read();
}
