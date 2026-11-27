# Site sync

This optional UCode plugin connects an OpenWrt OPL NetFleet node to an `opl-netfleet-cloud` control plane.

- **Zero-touch Gateway pairing (`site-sync-enroll` / LuCI `云端站点同步`)**: signs in once via OPL Gateway email and password (`/api/v1/agent/enroll`), stores only the returned single-site `device_token` (SHA-256 hashed on the server) and stable `device_id` in `0600` `/etc/opl-netfleet/site-sync/config.json`, and **never** persists the user password on the router.
- **Unenroll (`site-sync-disconnect`)**: revokes the device token via `/api/v1/agent/unenroll` and clears local sync credentials cleanly.
- **Fail-open telemetry & subscription sync**: sends only the bounded status projection accepted by the cloud heartbeat schema outside the network mutation lock, auto-derives valid UCI section IDs when `auto_sections` is enabled (or uses explicit `sections` mappings), and routes updates through `subscriptions-set` and `subscriptions-refresh`. Cloud failures or invalid responses leave local profiles and subscriptions untouched.
