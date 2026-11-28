const ERRORS = {
  invalid_cloud_origin: "请输入完整的 https:// 控制面地址（不可带尾部斜杠或路径）。",
  invalid_dispatched_origin: "云端下发的服务地址不符合安全校验规则，已拒绝接入。",
  credentials_required: "请填写 OPL Gateway 账号（邮箱）与密码。",
  invalid_totp_code: "请输入 6–8 位数字动态验证码。",
  requires_2fa: "该 OPL Gateway 账号已开启两步验证，请输入 6 位动态验证码后继续接入。",
  service_not_entitled: "当前 OPL Gateway 账号尚未开通 OPL NetFleet Cloud 服务权限，请联系平台管理员在 OPL Cloud 控制台开通。",
  rate_limited: "登录尝试过于频繁，请稍后再试。",
  cloud_discovery_unreachable: "无法连接 OPL Cloud 服务发现入口，请检查路由器网络连通性或确认高级设置中的地址。",
  enroll_unauthorized: "OPL Gateway 邮箱、密码或动态验证码校验失败，或账号状态未激活。",
  enroll_forbidden: "当前账号无权接入该云端控制面。",
  cloud_unreachable: "无法连接云端控制面，请检查网关网络连通性与目标服务状态。",
  site_conflict: "该站点 ID 已被其他账号占用，请清空或更换自定义站点 ID。",
  site_limit: "已达到当前账号允许纳管的云端站点数量上限。",
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
    needsTotp: false,
    status: null,
    notice: null,
    error: "",
    draftEmail: "",
    draftPassword: "",
    draftName: "",
    draftCloudOrigin: "",
    draftOrigin: "",
  };

  function clearFeedback() {
    state.error = "";
    state.notice = null;
  }

  function clearSensitiveDraft() {
    state.draftPassword = "";
    state.needsTotp = false;
  }

  async function refresh() {
    try {
      const data = await context.api.read("status");
      if (context.signal.aborted) return;
      state.status = data;
      state.loading = false;
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
    const email = String(fields.get("email") || "").trim();
    const password = String(fields.get("password") || "");
    const totpCode = String(fields.get("totp_code") || "").trim();
    const name = String(fields.get("name") || "").trim();
    const cloudOrigin = String(fields.get("cloud_origin") || "").trim().replace(/\/+$/, "");
    const origin = String(fields.get("origin") || "").trim().replace(/\/+$/, "");

    state.draftEmail = email;
    state.draftName = name;
    state.draftCloudOrigin = cloudOrigin;
    state.draftOrigin = origin;
    state.busy = true;
    render();
    try {
      const payload = {
        email,
        password,
        ...(totpCode ? { totp_code: totpCode } : {}),
        ...(name ? { name } : {}),
        ...(cloudOrigin ? { cloud_origin: cloudOrigin } : {}),
        ...(origin ? { origin } : {}),
      };
      const res = await context.api.call("enroll", payload);
      if (context.signal.aborted) return;
      clearSensitiveDraft();
      state.showReenroll = false;
      state.notice = `已成功接入云端站点「${res?.name || res?.site_id || ""}」，设备独立凭据已安全保存，密码未留存。`;
      await refresh();
    } catch (err) {
      if (context.signal.aborted) return;
      if (err?.message === "requires_2fa") {
        state.needsTotp = true;
        state.draftPassword = password;
      } else {
        clearSensitiveDraft();
      }
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
    clearSensitiveDraft();
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
    const advancedOpen = !!(state.draftCloudOrigin || state.draftOrigin);
    return E("form", { class: "nf-ss-form", submit: submitEnroll }, [
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
            value: state.draftEmail,
            placeholder: "name@example.com",
          }),
          E("small", {}, "无需输入云端网址；系统将向 OPL Cloud 自动核验服务权限并下发所属 NetFleet Cloud 地址。"),
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
            value: state.draftPassword,
            placeholder: "输入 OPL Gateway 登录密码",
          }),
          E("small", {}, "仅用于本次在线验证并换发当前路由器专属的单站 Device Token，密码绝不写入磁盘。"),
        ]),
      ]),
      state.needsTotp
        ? E("div", { class: "nf-ss-row" }, [
            E("label", { for: "nf-ss-totp" }, "两步验证码"),
            E("div", {}, [
              E("input", {
                id: "nf-ss-totp",
                name: "totp_code",
                type: "text",
                inputmode: "numeric",
                autocomplete: "one-time-code",
                maxlength: "16",
                required: true,
                disabled,
                placeholder: "输入 6 位动态验证码",
              }),
              E("small", {}, "该账号启用了两步验证，请输入验证器当前显示的动态口令。"),
            ]),
          ])
        : null,
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
      E("details", { class: "nf-ss-advanced", ...(advancedOpen ? { open: "" } : {}) }, [
        E("summary", {}, "高级设置（自建 OPL Cloud / 私有 NetFleet Cloud 地址，可选）"),
        E("div", { class: "nf-ss-advanced-body" }, [
          E("div", { class: "nf-ss-row" }, [
            E("label", { for: "nf-ss-cloud-origin" }, "OPL Cloud 发现入口（可选）"),
            E("div", {}, [
              E("input", {
                id: "nf-ss-cloud-origin",
                name: "cloud_origin",
                type: "url",
                disabled,
                value: state.draftCloudOrigin,
                placeholder: "https://cloud.medopl.com",
              }),
              E("small", {}, "仅当使用自建 OPL Cloud 控制面时填写（仅 HTTPS，不含末尾斜杠）。"),
            ]),
          ]),
          E("div", { class: "nf-ss-row" }, [
            E("label", { for: "nf-ss-origin" }, "直连私有控制面（可选）"),
            E("div", {}, [
              E("input", {
                id: "nf-ss-origin",
                name: "origin",
                type: "url",
                disabled,
                value: state.draftOrigin,
                placeholder: "https://your-self-hosted-netfleet-cloud",
              }),
              E("small", {}, "仅自建独立部署且不经 OPL Cloud 下发地址时填写；填写后将跳过统一服务发现。"),
            ]),
          ]),
        ]),
      ]),
      E("div", { class: "nf-ss-actions" }, [
        state.showReenroll
          ? E("button", {
              type: "button",
              class: "cbi-button cbi-button-reset",
              disabled: state.busy,
              click: () => {
                clearSensitiveDraft();
                state.showReenroll = false;
                render();
              },
            }, "取消")
          : null,
        E("button", {
          type: "submit",
          class: "cbi-button cbi-button-action",
          disabled,
        }, state.busy ? "正在登录配对…" : state.needsTotp ? "验证并接入云端" : "登录并接入云端"),
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
        E("p", { class: "nf-ss-sub" }, "仅需输入 OPL Gateway 账号密码即可自动发现并认领本路由器，集中监视出口质量并按授权子集同步订阅。"),
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
              clearSensitiveDraft();
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
    clearSensitiveDraft();
    style.remove();
    root.remove();
  });

  render();
  void refresh();
}
