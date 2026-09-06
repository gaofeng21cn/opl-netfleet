<p align="center">
  <img src="assets/branding/opl-netfleet-logo.png" alt="OPL NetFleet logo" width="136" />
</p>

<p align="center">
  <a href="./README.md">中文</a> | <strong>English</strong>
</p>

<h1 align="center">OPL NetFleet</h1>

<p align="center"><strong>A network enhancement plugin for OpenWrt</strong></p>
<p align="center">Multi-provider integration · layered selection · smooth switching · automatic recovery</p>

<p align="center">
  <a href="https://github.com/gaofeng21cn/opl-netfleet/actions"><img src="https://img.shields.io/github/actions/workflow/status/gaofeng21cn/opl-netfleet/netfleet-release.yml?label=checks" alt="Checks" /></a>
  <a href="https://github.com/gaofeng21cn/opl-netfleet/releases/latest"><img src="https://img.shields.io/github/v/release/gaofeng21cn/opl-netfleet" alt="Latest release" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="GPL-3.0 license" /></a>
</p>

NetFleet provides multi-provider network management on OpenWrt, either alongside
an existing Nikki + Mihomo installation or through its native Mihomo backend.
It organizes nodes by provider, region, and purpose,
chooses an appropriate exit from current measurements, and switches paths as
network conditions change.

You continue to use LuCI to view status, adjust preferences, and turn the
enhancement off. NetFleet keeps a native profile available as the recovery
destination, so a failed takeover can return the device to a familiar working
configuration.

## What You Get

- **One view for multiple providers.** See providers, regions, nodes, latency, and subscription usage together.
- **A clear path to a better exit.** NetFleet compares regions, provider tiers, and individual nodes in that order.
- **Purpose-based exits.** Standard traffic and services with region requirements can use separate capabilities, or share a region when conditions allow.
- **Primary and reserve tiers.** Normal traffic prefers primary providers, then reserve providers, and finally `DIRECT`.
- **Continuous health checks.** Scheduled refreshes update subscriptions, measurements, transparent proxy, and DNS state.
- **Controlled activation.** Setup, candidate generation, and live takeover are separate steps with visible state and a native recovery profile.

## Design Approach

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

Mihomo owns connections and node health; NetFleet owns the shared policy,
cross-provider selection, and recovery transactions. Nikki mode retains Nikki's
subscription and data-plane lifecycle. Native mode manages these resources in
an independent namespace, reusing pinned Nikki configuration projections and
nft templates rather than adding another node selector or parallel controller.

Read the [product whitepaper](docs/product/whitepaper.md) for the full rationale
and the [architecture overview](docs/architecture/overview.md) for current
implementation behavior.

## Current Features

The current source provides native LuCI pages and a device-side runtime with the
following interfaces. Source availability does not establish that a particular
release asset or device has passed qualification; check the release's source
identity and supported backend before installation.

- first-run discovery of the selected backend's profile, provider caches, regions, and entry group;
- explicit native Mihomo setup on an unconfigured device and transactional migration from a working Nikki installation;
- native subscription creation, editing, deletion, and individual refresh without exposing saved credentials in public status;
- primary/reserve provider roles and region scope settings;
- automatic region selection for `standard` and `ai-compatible` capabilities;
- provider, region, and node health checks;
- protected probes, layered Fail-Open, and native profile recovery;
- provider, region, node, subscription, event, and connection diagnostics;
- a separate full Zashboard for live Mihomo connections, traffic, rule matches, and proxy groups;
- scheduled subscription refresh, configuration compilation, and automatic selection;
- native IPv4/IPv6 TCP and UDP transparent proxying, plus LAN and router-local DNS handling;
- native network settings for DNS upstreams and domain overrides, LAN/router proxy scope, device rules, listeners, and authentication;
- domain-suffix and IPv4/IPv6 CIDR rules targeting an exit capability or direct connectivity;
- local profile import, download, controlled editing, and backup/restore of NetFleet's private configuration;
- core restart, reload, sanitized startup logs, and separate Zashboard resource version checks and updates;
- OpenWrt APK/IPK packages, signed APK feeds, and Fleet declarative deployment.

NetFleet keeps stable operational summaries on its Events and Diagnostics page.
The **Zashboard** entry opens the full dashboard in a new tab using the
selected backend's controller and resources. Both backends use the same entry
and Zashboard's secret-bearing connection URL. These temporary credentials must
not enter NetFleet logs or display caches.

Native network integration currently supports TProxy. Mihomo also supports TUN
and Redirect, but NetFleet has not adapted and qualified their OpenWrt takeover,
cleanup, and failure recovery, so the UI does not expose a mode switch. Native
network, profile, and resource management belong to the native backend; Nikki
mode retains Nikki's ownership of the corresponding resources.

## Installation

### Prerequisites

The target device should have:

- a working OpenWrt package manager;
- Mihomo and the OpenWrt dependencies required by the selected package;
- for Nikki mode: a working Nikki installation, an independently usable native profile, and at least one valid subscription cache;
- for native setup: a package containing native-backend support, working upstream DNS, and a valid subscription, without another proxy core occupying the network.

On OpenWrt 25.12, use the one-time installer to add the signed feed and install
both packages:

```sh
uclient-fetch -q -O /tmp/install-netfleet.sh https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/install-netfleet.sh && sh /tmp/install-netfleet.sh
```

This command installs only the APK key, repository, and program files. It does
not write policy, subscriptions, or Nikki mixins, and it does not take over the
network automatically.

Open **Services -> NetFleet** in LuCI. A working Nikki installation enters
discovery directly. An unconfigured device first uses **Set Up Mihomo**, with
explicit confirmation before subscription download and network takeover. The
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
Mihomo version, and key dependencies, with an explicit feed check. NetFleet and
its LuCI interface update together. Updating Mihomo under the native backend
requires separate confirmation and validates the current configuration first;
failures restore the previous packages and runtime. Unattended and system-wide
upgrades are not enabled by default.

The separate Zashboard section checks and updates official static resources
without restarting Mihomo or changing its connection credentials. An unknown
installed version is shown as unrecorded rather than inferred from file times;
available versions appear after an explicit check. Package, core, and dashboard
updates require separate confirmation and are not silently bundled together.

After the first installation, OpenWrt can upgrade directly from the configured
feed:

```sh
apk update && apk upgrade opl-netfleet luci-app-netfleet
```

Package upgrades refresh program files while keeping policy, subscription
caches, and the active configuration in place. Re-running the one-time
installer adds any missing NetFleet packages, then upgrades only the two named
packages without proactively upgrading already-satisfied dependencies. Keep the
package names in the upgrade command to avoid a system-wide upgrade. It does not recreate
instance configuration. Review the status page after the upgrade and apply a
new configuration when ready.

## Everyday Use

### Configuration And Maintenance

**Configuration -> Network Access** manages the native backend's DNS, proxy
scope, device rules, listeners, and authentication. Changes are validated before
application and restore the previous configuration on failure; this surface does
not edit OpenWrt WAN/LAN addresses or its default route. Configure domain and
network traffic rules under **Business Rules**.

**Configuration -> Profiles and Backup** imports, downloads, and edits local
profiles and exports or restores NetFleet backups. A profile currently in use
cannot be overwritten or deleted directly. Backups contain private subscription
addresses and credentials, not system firmware, and should be stored securely.

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

### Closing And Recovery

Disabling NetFleet switches back to the Recovery Profile selected during setup
and checks the selected backend, Mihomo, transparent proxy, and DNS state. Only
if the recovery profile cannot be restored does that backend's cleanup restore
direct networking. The native gateway removes only the network state it owns,
and the device reports the actual business probe result.

## Fleet Deployment

Direct LuCI setup suits a single device. For reproducible multi-device rollout,
use the Fleet deployment entry point with a bundle rendered by a private OPL
Instance:

```bash
scripts/deploy-openwrt.sh <ssh-target> --ref <release-or-commit> \
  --packages /private/path/netfleet-packages \
  --instance /private/path/deployment-bundle
```

The bundle contains policy, subscription references, a backend mixin, and a
platform declaration. The default path installs, compiles, and reads back a
staged result. Add `--activate` after the same source has passed OpenWrt QEMU
qualification to enable the target and perform the final readback. An existing
Nikki bundle and native migration remain distinct entry points; changing a
backend name is not a substitute for migration.

For rollout, complete the full compile, enable, readback, and disable cycle on
a locally recoverable canary before promoting the same package and configuration
to separately authorized replicas. See [Canary promotion and recovery](docs/operations/canary-promotion.md).

## Development

Fast source and contract checks:

```bash
scripts/check-fast.sh
```

Full fake-device deployment matrix:

```bash
scripts/check-full.sh
```

The React/Vite surface is a quick local reference for information hierarchy and
interaction. Native LuCI remains the device surface:

```bash
cd ui
bun install
NETFLEET_UI_TARGET=<ssh-alias> NETFLEET_UI_TARGET_LABEL="Canary" bun run dev
```

## Documentation And License

- [Documentation index](docs/README.md)
- [Architecture overview](docs/architecture/overview.md)
- [Independent device management](docs/architecture/management.md)
- [UI design](docs/design/ui.md)
- [Product whitepaper](docs/product/whitepaper.md)
- [Development and device-operation rules](AGENTS.md)

The combined distribution containing Nikki-derived modules is distributed under
[GNU GPL 3.0](./LICENSE). Original NetFleet files retain their Apache-2.0 notices;
the license text remains in [LICENSE.Apache-2.0](openwrt/files/usr/share/opl-netfleet/LICENSE.Apache-2.0).
Imported Nikki modules retain their GPL-3.0 license, copyright, pinned upstream
revision, and [modification notice](openwrt/files/usr/share/opl-netfleet/nikki/NOTICE).
Combining the distribution does not remove third-party notices.
