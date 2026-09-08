<p align="center">
  <img src="assets/branding/opl-netfleet-logo.png" alt="OPL NetFleet logo" width="136" />
</p>

<p align="center">
  <a href="./README.md">中文</a> | <strong>English</strong>
</p>

<h1 align="center">OPL NetFleet</h1>

<p align="center"><strong>A microkernel-based proxy and network management platform for OpenWrt</strong></p>
<p align="center">Independent Mihomo management · multi-provider selection · composable plugins · independent hot replacement</p>

<p align="center">
  <a href="https://github.com/gaofeng21cn/opl-netfleet/actions"><img src="https://img.shields.io/github/actions/workflow/status/gaofeng21cn/opl-netfleet/netfleet-release.yml?label=checks" alt="Checks" /></a>
  <a href="https://github.com/gaofeng21cn/opl-netfleet/releases/latest"><img src="https://img.shields.io/github/v/release/gaofeng21cn/opl-netfleet" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache-2.0 license" /></a>
</p>

NetFleet brings subscriptions, traffic rules, automatic routing, DNS, transparent
proxying, and maintenance into one LuCI interface. Native mode manages Mihomo
directly and supports first-time setup on OpenWrt without a running Nikki service.
Existing Nikki users can keep their environment or migrate to NetFleet's native backend.

It organizes connectivity around providers, regions, and business exits, using
current measurements to choose paths and primary, reserve, and direct tiers to
handle failures. The microkernel coordinates service composition and lifecycle;
plugins provide subscriptions, policy, backends, selection, recovery, and
management. Single-device setup and declarative Fleet deployment share the same
runtime logic.

## What You Get

- **Independent proxy management.** Native mode covers subscriptions, profiles, DNS, transparent proxying, core maintenance, and backup/restore.
- **Multiple providers in one place.** View regions, nodes, latency, and usage; assign primary and reserve roles to provide alternatives when individual paths fail.
- **Automatic exits for each purpose.** Standard traffic and region-constrained services can use distinct capabilities, with visible selections and switching reasons.
- **Composable feature plugins.** Services, business actions, configuration, and pages use one plugin protocol with independent installation, updates, and hot replacement. First-party and third-party developers share the same interfaces and tools.
- **Explicit network operating modes.** Switch between native OpenWrt direct networking, native Mihomo proxying, and NetFleet enhanced proxying, with separate control of the core, network interception, and scheduling. See [operating modes](docs/architecture/runtime-and-recovery.md#用户运行模式).
- **Reproducible device configuration.** Fleet deploys an explicit version, validates and compiles on the device, and reads back the result.

## Two Ways To Connect

| Mode | Best suited for | Management responsibilities |
| --- | --- | --- |
| **NetFleet + Mihomo (native)** | New installations or unified NetFleet management | NetFleet manages subscriptions, profiles, core services, DNS, and transparent proxying, without running Nikki services |
| **Nikki + Mihomo** | Working Nikki installations adding multi-provider selection and recovery | Nikki retains subscription and data-plane management; NetFleet supplies shared policy, selection, and recovery transactions |

The backends are explicitly selected and mutually exclusive, with migration
preflight checks and rollback. Native mode reuses pinned Nikki configuration
projections and nft templates, preserving their upstream attribution and licenses.
Current network integration uses TProxy.

## Design Highlights

### Declarative Policy And Layered Selection

NetFleet separates what a user needs from the node that happens to provide it.
Rules select stable capabilities such as standard connectivity or a
region-constrained service. Providers and nodes remain replaceable resources.
Adding a provider or replacing a node therefore does not require rewriting the
user's rules.

Selection has three layers:

1. **Region** shapes distance, availability, and connection experience.
2. **Provider** represents an independent service and quota domain.
3. **Node** is selected and refreshed by Mihomo URLTest within the chosen region.

Each round uses current measurements and a switch margin, keeping the active
path stable during small latency fluctuations. History helps explain what the
device has seen; the current choice follows the latest healthy measurements.

### Microkernel, Plugin Composition, And Hot Updates

NetFleet organizes business logic, platform capabilities, and interfaces into
feature plugins. The kernel handles discovery, service binding, dependency
resolution, call admission, and resource lifecycle. Subscriptions, selection,
compilation, recovery, backends, and scheduling run through composed services.
A plugin can contribute services, CLI commands, browser actions, configuration,
and pages. The host discovers installed contributions without changes to its RPC
or navigation tables.

System configuration selects service providers and supports named instances with
local bindings and configuration. One plugin can serve multiple distinct
compositions. Service and page scopes own listeners, connections, and cleanup
callbacks, releasing their resources when a call ends, a page closes, or a plugin
unloads. Administrators can edit the composition JSON under **Components and
Updates -> Service Composition**, validate dependencies and preview affected
plugins, then confirm application. A failed change restores the previous
composition and resource state.

The selection algorithm has its own package. Separate platform plugins provide
storage, OpenWrt configuration, and runtime management; the kernel also receives
system operations through an injected host adapter. Business services can be
reused through capability bindings. See the
[platform capability boundary](docs/architecture/microkernel.md#平台能力边界).

There are two development paths. **UCode service plugins** compose capabilities
through declared dependencies and `context.use()`. **Process plugins** use
Extension API v1 with Shell, Python, or another runtime available on the device.
Both share the installation directory, management entry points, and packaging
workflow. Any plugin implementing the protocol can be discovered, loaded, and
hot-replaced.

Each call uses current plugin code. Updates wait for in-flight calls to finish,
and new calls use the new version. Updating a plugin outside Mihomo's resource
dependency graph, such as the selection algorithm, does not restart Mihomo.
Resource plugins run their drain and resume lifecycle when their code or
dependencies change. The browser discovers changes to the plugin inventory,
disposes the old page, and loads the current version. Pages, imported modules,
and styles share a resource directory bound to the same code revision.

| Feature plugin | Purpose | Delivery and runtime behavior |
| --- | --- | --- |
| **Default network functions** | Subscriptions, compilation, selection, activation, recovery, configuration, and scheduling | `opl-netfleet` composes the default product; each feature plugin has its own package |
| **Product interface** | Overview, exits, providers, regions, configuration, components, and diagnostics | `product-ui` contributes seven pages; the LuCI shell handles discovery, navigation, and page lifecycle |
| **HTTPS compatibility** | HTTP/1.1-to-HTTP/2 compatibility for selected devices and destinations | A management plugin connects the optional converter package; explicit onboarding after device trust in a private CA, with bypass to the original route on failure |
| **Zashboard** | Live Mihomo connections, traffic, rule matches, and proxy groups | A separate Dashboard plugin manages the entry and resources; dashboard assets can be updated without restarting Mihomo |
| **Developer examples** | Independent services, saved configuration, and interactive pages | `workspace-note` is a complete external plugin; `host-info` and `device-info` demonstrate minimal service composition and process entry points |

First-party and third-party developers use the same scaffolding, manifest
validation, OpenWrt packaging, and signed distribution workflow. Start with the
[plugin development and installation guide](docs/development/plugins.md). See
[Microkernel and feature plugins](docs/architecture/microkernel.md) for service
and hot-replacement contracts, and [Modules and extensions](docs/architecture/extensions.md)
for process interfaces and component management.

### Local Execution And Recovery First

The UCode runtime runs on OpenWrt, Mihomo handles connections and health checks
within node groups, and LuCI presents state and submits scoped operations.
Runtime and recovery work without an open browser, cloud controller, or Node.js host.

Configuration is validated and staged before explicit activation and runtime
checks. Leaving enhanced mode or recovering first returns to an independently usable
Recovery Profile. Explicitly choosing native OpenWrt direct mode stops the proxy
and removes its network takeover. The recovery plugin coordinates this
shared path, while resource plugins handle their own failure exits.

Read the [product whitepaper](docs/product/whitepaper.md) for the full rationale
and the [architecture overview](docs/architecture/overview.md) for current
implementation behavior.

NetFleet script and UI packages are `noarch`; the Mihomo core currently supplied
by the feed covers ARM64 `aarch64_generic` only. Other architectures need an
already compatible core. Portable code packages do not imply complete fresh-device
support. See the chosen release and the [package contract](docs/architecture/packaging.md).

## Installation

### Prerequisites

The target device should have:

- a working OpenWrt package manager;
- Mihomo and the OpenWrt dependencies required by the selected package;
- for native setup: a package containing native-backend support, working upstream DNS, and a valid subscription, without another proxy core occupying the network;
- for Nikki mode: a working Nikki installation, an independently usable native profile, and at least one valid subscription cache.

On OpenWrt 25.12, use the one-time installer to add the signed feed and install
the default product and LuCI. The package manager resolves the microkernel and
feature-plugin dependencies:

```sh
uclient-fetch -q -O /tmp/install-netfleet.sh https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/install-netfleet.sh && sh /tmp/install-netfleet.sh
```

This command installs only the APK key, repository, and program files. It does
not write policy, subscriptions, or Nikki mixins, and it does not take over the
network automatically.

Open **Services -> NetFleet** in LuCI. An unconfigured device first uses
**Set Up Mihomo**, with explicit confirmation before subscription download and
network takeover. A working Nikki installation enters discovery directly. The
shared first-run setup then:

1. discover the native profile, provider caches, regions, and the `MATCH` entry group;
2. check the environment and show a recommended configuration;
3. generate and compile the policy after your confirmation;
4. start NetFleet and read back runtime and probe status.

Subscriptions remain in the selected backend's private configuration, outside
policy and public status. After setup, LuCI can maintain provider roles, region
scope, capabilities, business bindings, domain/CIDR rules, automation, and
protected probes. Native credentials use the separate subscription management
entry. Saving a changed source does not stop the network; the last accepted
cache remains in use until an explicit refresh succeeds.

To move a working Nikki installation, use **Configuration -> Foundation ->
Migrate to NetFleet Native Backend**. The transaction checks resources and
business connectivity, leaves only the native backend running on success, and
restores the previous backend on failure. Backend migration is distinct from a
normal package upgrade and never establishes permanent dual writes.

## Upgrading

The LuCI **Components and Updates** page shows installed versions, the running
Mihomo version, and key dependencies, with an explicit feed check. NetFleet
updates the microkernel, feature plugins, and LuCI together using the default
product inventory; third-party plugins can be maintained independently.
Updating Mihomo under the native backend
requires separate confirmation and validates the current configuration first;
failures restore the previous packages and runtime. Unattended and system-wide
upgrades are not enabled by default.

The separate Zashboard section checks and updates official static resources
without restarting Mihomo or changing its connection credentials. Installed
versions come from valid installation records or local asset inspection and are
shown as unknown when unidentifiable. Available versions appear after an explicit
check. Package, core, and dashboard
updates require separate confirmation and are not silently bundled together.

Use the component page to update the complete product. Individual feature
plugins can also be updated directly from the configured feed, for example:

```sh
apk update && apk upgrade opl-netfleet-plugin-selection-algorithm
```

Upgrades retain policy, subscription caches, and system service bindings. Package
hooks drain and resume around code replacement. Review versions and runtime
state on the component and status pages after upgrading; new configurations
still require explicit application. See the [development and installation
guide](docs/development/plugins.md) for plugin installation, upgrades, and removal.

## Everyday Use

### Configuration And Maintenance

**Configuration -> Network Access** manages the native backend's DNS, proxy
scope, device rules, listeners, and authentication. Changes are validated before
application and restore the previous configuration on failure; this surface does
not edit OpenWrt WAN/LAN addresses or its default route. Configure domain and
network traffic rules under **Business Rules**.

**Configuration -> Profiles and Backup** imports, downloads, and edits local
profiles and exports or restores NetFleet backups. A profile currently in use
cannot be overwritten or deleted directly. Backups include private subscriptions,
service composition, instance configuration, and persistent plugin data. Restore
checks required plugins and interface compatibility; plugin code is installed
from signed packages. Backups contain private data, not system firmware, and
should be stored securely.

**Events and Diagnostics** provides core restart, reload, and on-demand startup
logs. Startup failures remain inspectable when the Mihomo controller is
unavailable. See [Independent device management](docs/architecture/management.md)
for management and recovery boundaries.

### Automatic Selection

When enabled, NetFleet refreshes subscriptions on schedule and runs one bounded
health-check round. The root capability chooses a region first. A capability
with additional region requirements follows that region when it qualifies, or
chooses its own fastest qualified region. Mihomo URLTest keeps the node inside
that region healthy.

The visible fallback order is:

```text
preferred -> other primary providers -> reserve providers -> DIRECT
```

LuCI shows the active capability, region, provider, node, selection reason, and
fallback state.

### Mode Switching And Recovery

Native Mihomo mode stops enhanced scheduling while retaining native proxying.
Native OpenWrt direct mode stops the proxy and removes network takeover. After
each transition, the UI reads actual runtime state; business probes remain separate
evidence of reachability. See [operating modes](docs/architecture/runtime-and-recovery.md#用户运行模式)
for the authoritative behavior and recovery rules.

## Fleet Deployment

Direct LuCI setup suits a single device. Use **Components and Updates** for
routine software updates, and the device setup or migration entry point for
native onboarding. To reproduce **Nikki environments** across devices, use the
Fleet entry point with a bundle rendered by a private OPL Instance:

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref <release-or-commit> \
  --packages /private/path/netfleet-packages \
  --instance /private/path/deployment-bundle
```

The bundle contains policy, subscription references, a backend mixin, and a
platform declaration. The default path installs, compiles, and reads back a
staged result. Add `--activate` after the same source has passed OpenWrt QEMU
qualification to enable the target and perform the final readback. This four-file
projection targets Nikki environments; updating a native device does not apply a
Nikki bundle or start Nikki. See [deployment entry points](docs/operations/deployment.md#按设备当前状态选择入口).

For rollout, complete the full compile, enable, readback, and disable cycle on
a locally recoverable canary before promoting the same package and configuration
to separately authorized replicas. See [Canary promotion and recovery](docs/operations/canary-promotion.md).

## Development

Create a complete plugin with a service, configuration actions, and a page:

```bash
python3 scripts/netfleet-plugin.py scaffold my-plugin /tmp/my-plugin --kind service --template complete
python3 scripts/netfleet-plugin.py validate /tmp/my-plugin
```

The generated directory can be developed, packaged, and distributed from an
independent repository. Omit `--template complete` for the minimal service
template, or use `--kind process` for a process plugin. The complete `workspace-note`
example, instance configuration, SDK packaging, and signed installation are covered in
[Plugin development and installation](docs/development/plugins.md).

Fast source and contract checks:

```bash
scripts/check-fast.sh
```

Full fake-device deployment matrix:

```bash
scripts/check-full.sh
```

The local React/Vite app supports the same page plugin host and retains live
read-only and offline reference development entry points. On devices, the LuCI
shell loads pages contributed by installed plugins:

```bash
cd ui
bun install
NETFLEET_UI_TARGET=<ssh-alias> NETFLEET_UI_TARGET_LABEL="Canary" bun run dev
```

## Documentation And License

- [Documentation index](docs/README.md)
- [Architecture overview](docs/architecture/overview.md)
- [Microkernel and feature plugins](docs/architecture/microkernel.md)
- [Independent device management](docs/architecture/management.md)
- [Modules and extensions](docs/architecture/extensions.md)
- [Plugin development and installation](docs/development/plugins.md)
- [HTTPS compatibility](docs/architecture/https-compatibility.md)
- [UI design](docs/design/ui.md)
- [Product whitepaper](docs/product/whitepaper.md)
- [Development and device-operation rules](AGENTS.md)

OPL NetFleet is licensed under [Apache License 2.0](./LICENSE) by default,
except for files with explicit alternative license notices. LuCI and other
MIT-licensed files retain their notices.
The combined distribution containing Nikki-derived modules remains subject to
[GNU GPL 3.0](openwrt/files/usr/share/opl-netfleet/nikki/LICENSE). Original NetFleet files retain their Apache-2.0 notices;
the license text remains in [LICENSE.Apache-2.0](openwrt/files/usr/share/opl-netfleet/LICENSE.Apache-2.0).
Imported Nikki modules retain their GPL-3.0 license, copyright, pinned upstream
revision, and [modification notice](openwrt/files/usr/share/opl-netfleet/nikki/NOTICE).
Combining the distribution does not remove third-party notices.
