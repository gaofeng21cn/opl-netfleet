const ERRORS = {
  invalid_cloud_origin: "请输入完整的 https:// 云端控制面地址（不可带尾部斜杠或路径）。",
  credentials_required: "请填写 OPL Gateway 账号（邮箱）与密码。",
  enroll_unauthorized: "OPL Gateway 邮箱或密码验证失败，或该账号不在云端管理员白名单内。",
  cloud_unreachable: "无法连接云端控制面，请检查网关网络连通性与云端地址是否正确。",
  site_conflict: "该站点 ID 已被其他账号占用，请清空或更换自定义站点 ID。",
  site_limit: "云端纳管站点数量已达上限（64）。",
  unsafe_sync_storage: "路由器本地私有存储目录权限异常，请检查 /etc/opl-netfleet 权限。",
  heartbeat_failed: "云端心跳上报未成功，请检查云端地址与本机联网状态。",
};

function formatTime(epochSec) {
  if (!epochSec || !Number.isFinite(epochSec)) return "尚未尝试";
  return new Date(epochSec * 1000).toLocaleString();
}

function errorText(error) {
  const code = error?.message || String(error || "");
  return ERRORS[code] || `操作失败：${code || "未知错误"}`;
}

export async function mount(context) {
  if (context.signal.aborted) return;

  const resourceUrl = (name) => new URL(name, import.meta.url).href;
  const style = document.createElement("link");
  style.rel = "stylesheet";
  style.href = resourceUrl("style.css");
  const root = document.createElement("div");
  root.className = "netfleet-sitesync-plugin";
  context.container.append(style, root);

  const state = {
    loading: true,
    busy: false,
    showReenroll: false,
    status: null,
    notice: null,
    error: "",
    draftOrigin: "",
    draftName: "",
  };

  function clearFeedback() {
    state.error = "";
    state.notice = null;
  }

  async function refresh() {
    try {
      const data = await context.api.read("status");
      if (context.signal.aborted) return;
      state.status = data;
      state.loading = false;
      if (!state.draftOrigin && data?.origin) state.draftOrigin = data.origin;
      if (!state.draftName) state.draftName = data?.name || data?.hostname || "";
      render();
    } catch (err) {
      if (context.signal.aborted) return;
      state.loading = false;
      state.error = errorText(err);
      render();
    }
  }

  async function submitEnroll(event) {
    event.preventDefault();
    if (state.busy || context.readOnly) return;
    clearFeedback();
    const form = event.currentTarget;
    const fields = new FormData(form);
    const origin = String(fields.get("origin") || "").trim().replace(/\/+$/, "");
    const email = String(fields.get("email") || "").trim();
    const password = String(fields.get("password") || "");
    const name = String(fields.get("name") || "").trim();

    state.draftOrigin = origin;
    state.draftName = name;
    state.busy = true;
    render();
    try {
      const res = await context.api.call("enroll", {
        origin,
        email,
        password,
        ...(name ? { name } : {}),
      });
      if (context.signal.aborted) return;
      state.showReenroll = false;
      state.notice = `已成功接入云端站点「${res?.name || res?.site_id || ""}」，设备独立凭据已安全保存，密码未留存。`;
      await refresh();
    } catch (err) {
      if (context.signal.aborted) return;
      state.error = errorText(err);
    } finally {
      state.busy = false;
      if (!context.signal.aborted) render();
    }
  }

  async function triggerSyncNow() {
    if (state.busy || context.readOnly) return;
    clearFeedback();
    state.busy = true;
    render();
    try {
      const data = await context.api.call("sync-now", {});
      if (context.signal.aborted) return;
      state.status = data;
      state.notice = "已完成一次云端心跳上报与订阅版本核对。";
    } catch (err) {
      if (context.signal.aborted) return;
      state.error = errorText(err);
    } finally {
      state.busy = false;
      if (!context.signal.aborted) render();
    }
  }

  async function triggerDisconnect() {
    if (state.busy || context.readOnly) return;
    if (!window.confirm("确定断开当前路由器的云端站点同步？云端该站点的设备凭据将被立即吊销，本地既有订阅不会删除。")) {
      return;
    }
    clearFeedback();
    state.busy = true;
    render();
    try {
      const data = await context.api.call("disconnect", {});
      if (context.signal.aborted) return;
      state.status = data;
      state.showReenroll = false;
      state.notice = "已断开云端站点同步并吊销本机设备凭据。";
    } catch (err) {
      if (context.signal.aborted) return;
      state.error = errorText(err);
    } finally {
      state.busy = false;
      if (!context.signal.aborted) render();
    }
  }

  function renderForm() {
    const disabled = state.busy || context.readOnly;
    return E("form", { class: "nf-ss-form", submit: submitEnroll }, [
      E("div", { class: "nf-ss-row" }, [
        E("label", { for: "nf-ss-origin" }, "云端控制面地址"),
        E("div", {}, [
          E("input", {
            id: "nf-ss-origin",
            name: "origin",
            type: "url",
            required: true,
            disabled,
            value: state.draftOrigin,
            placeholder: "https://your-cloud-origin",
          }),
          E("small", {}, "填写你的 opl-netfleet-cloud 访问地址（仅 HTTPS 协议，不含末尾斜杠）。"),
        ]),
      ]),
      E("div", { class: "nf-ss-row" }, [
        E("label", { for: "nf-ss-email" }, "OPL Gateway 账号（邮箱）"),
        E("div", {}, [
          E("input", {
            id: "nf-ss-email",
            name: "email",
            type: "email",
            required: true,
            disabled,
            autocomplete: "username",
            placeholder: "name@example.com",
          }),
        ]),
      ]),
      E("div", { class: "nf-ss-row" }, [
        E("label", { for: "nf-ss-password" }, "密码"),
        E("div", {}, [
          E("input", {
            id: "nf-ss-password",
            name: "password",
            type: "password",
            required: true,
            disabled,
            autocomplete: "current-password",
            placeholder: "输入 OPL Gateway 登录密码",
          }),
          E("small", {}, "仅用于本次在线验证并换发当前路由器专属的单站 Device Token，密码绝不写入磁盘。"),
        ]),
      ]),
      E("div", { class: "nf-ss-row" }, [
        E("label", { for: "nf-ss-name" }, "云端展示名称（可选）"),
        E("div", {}, [
          E("input", {
            id: "nf-ss-name",
            name: "name",
            type: "text",
            maxlength: "120",
            disabled,
            value: state.draftName,
            placeholder: state.status?.hostname || "OpenWrt",
          }),
          E("small", {}, "留空则默认使用当前路由器主机名；连接后也可随时在云端控制台重命名。"),
        ]),
      ]),
      E("div", { class: "nf-ss-actions" }, [
        state.showReenroll
          ? E("button", {
              type: "button",
              class: "cbi-button cbi-button-reset",
              disabled: state.busy,
              click: () => {
                state.showReenroll = false;
                render();
              },
            }, "取消")
          : null,
        E("button", {
          type: "submit",
          class: "cbi-button cbi-button-action",
          disabled,
        }, state.busy ? "正在登录配对…" : "登录并接入云端"),
      ]),
    ]);
  }

  function render() {
    if (context.signal.aborted) return;
    const s = state.status;
    const connected = s?.connected === true;

    const header = E("div", { class: "nf-ss-head" }, [
      E("div", {}, [
        E("h3", {}, "云端站点同步（OPL NetFleet Cloud）"),
        E("p", { class: "nf-ss-sub" }, "通过 OPL Gateway 账号直接认领本路由器，集中监视出口质量并按授权子集自动同步订阅。"),
      ]),
      E("span", { class: connected ? "nf-ss-badge is-ok" : "nf-ss-badge" }, connected ? "已接入" : "未接入"),
    ]);

    const feedback = [];
    if (state.error) {
      feedback.push(E("div", { class: "nf-ss-alert is-error", role: "alert" }, state.error));
    }
    if (state.notice) {
      feedback.push(E("div", { class: "nf-ss-alert is-ok", role: "status" }, state.notice));
    }

    let body;
    if (state.loading) {
      body = E("p", { class: "nf-ss-sub" }, "正在读取云端同步状态…");
    } else if (connected && !state.showReenroll) {
      body = E("div", { class: "nf-ss-connected" }, [
        E("dl", { class: "nf-ss-grid" }, [
          E("div", {}, [E("dt", {}, "云端控制面"), E("dd", {}, E("code", {}, s.origin || "—"))]),
          E("div", {}, [E("dt", {}, "站点名称 / ID"), E("dd", {}, `${s.name || "—"} (${s.site_id || "—"})`)]),
          E("div", {}, [E("dt", {}, "已应用 / 期望版本"), E("dd", {}, `${s.applied_revision ?? 0} / ${s.desired_revision ?? "—"}`)]),
          E("div", {}, [E("dt", {}, "最近一次心跳"), E("dd", {}, `${formatTime(s.last_attempted_at)}${s.last_error ? ` · 异常：${s.last_error}` : s.last_ok === true ? " · 正常" : ""}`)]),
        ]),
        E("div", { class: "nf-ss-actions" }, [
          E("button", {
            type: "button",
            class: "cbi-button cbi-button-action",
            disabled: state.busy || context.readOnly,
            click: triggerSyncNow,
          }, state.busy ? "执行中…" : "立即同步一次"),
          E("button", {
            type: "button",
            class: "cbi-button cbi-button-neutral",
            disabled: state.busy || context.readOnly,
            click: () => {
              state.showReenroll = true;
              render();
            },
          }, "重新登录配对"),
          E("button", {
            type: "button",
            class: "cbi-button cbi-button-negative",
            disabled: state.busy || context.readOnly,
            click: triggerDisconnect,
          }, "断开云端同步"),
        ]),
      ]);
    } else {
      body = renderForm();
    }

    const boundary = E("div", { class: "nf-ss-foot" },
      "安全边界：云端断网或响应异常时设备自动 Fail-Open 保留当前订阅与分流策略，不暴露局域网客户端或订阅原文。");

    root.replaceChildren(header, ...feedback, body, boundary);
  }

  context.scope.effect(() => {
    style.remove();
    root.remove();
  });

  render();
  void refresh();
}
