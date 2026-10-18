# CLIProxyAPI Usage for Noctalia

A [Noctalia](https://noctalia.dev) v5 bar widget and panel that shows subscription quota
from a [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) instance, pooled across
every account the proxy routes through.

Other usage widgets read each CLI's own credentials, one account at a time. When your
Claude and Codex accounts sit behind CLIProxyAPI, the proxy already knows every account's
5-hour and weekly windows from the rate-limit headers of real traffic, along with routing
order, cooldowns and accounts that need a relogin. This plugin reads that one view.

## What it shows

- **Bar:** one capsule group per provider. The 5-hour window appears as a percentage and a
  gauge, with a thinner 7-day bar under it. The reading is the mean across the provider's
  enabled accounts. Hover for the windows, reset countdowns and account count.
- **Panel** (left click): every account in routing order, with plan, all of its quota
  windows (including Codex's named limits and Claude's per-model windows), reset
  countdowns, cooldown and relogin badges, request counts and active proxy alerts.
  Press `R` to refresh.
- Right click refreshes without waiting for the interval.

## Requirements

- Noctalia with plugin API 32 or newer.
- CLIProxyAPI with the v8 management API (`/v8/management/routing/overview`) and
  `remote-management.secret-key` set.

## Install

Clone into Noctalia's local plugin directory, which takes precedence over every plugin
source, and enable it:

```sh
git clone https://github.com/subsy/noctalia-cliproxy-usage \
  "${XDG_DATA_HOME:-$HOME/.local/share}/noctalia/plugins/cliproxy-usage"
noctalia msg plugins enable subsy/cliproxy-usage
```

Store the management key, which is the plaintext value of `remote-management.secret-key`.
CLIProxyAPI replaces it with a bcrypt hash on startup, so the config file no longer
contains it:

```sh
mkdir -p ~/.config/cliproxy-usage
read -rs 'k?Management key: '   # bash: read -rsp 'Management key: ' k
printf %s "$k" > ~/.config/cliproxy-usage/management-key
chmod 600 ~/.config/cliproxy-usage/management-key
```

Then add `subsy/cliproxy-usage:bar` to a bar in **Settings → Bar**, or by hand:

```toml
[widget.cliproxy_usage]
type = "subsy/cliproxy-usage:bar"

[bar.default]
end = [ "cliproxy_usage", "clock" ]
```

## Settings

Plugin-level, shared by the poller, the capsules and the panel:

| Setting | Default | Description |
| --- | --- | --- |
| `base_url` | `http://127.0.0.1:8317` | Proxy base URL. |
| `key_file` | `~/.config/cliproxy-usage/management-key` | File holding the plaintext management key. A file keeps the key out of Noctalia's settings. |
| `refresh_seconds` | `60` | Seconds between reads, 15 to 3600. |
| `usage_display` | `remaining` | Show the `remaining` or `used` share. Colors always follow consumption. |
| `show_disabled` | `false` | List accounts disabled in CLIProxyAPI in the panel, dimmed. They never count toward the pooled reading. |

Per bar widget:

| Setting | Default | Description |
| --- | --- | --- |
| `providers` | `[]` | Provider ids to show, such as `claude` or `codex`. Empty shows all with quota data. |
| `show_value` | `true` | Show the percentage. |
| `show_gauge` | `true` | Show the 5-hour and 7-day bars. |
| `show_countdown` | `false` | Show the soonest 5-hour reset beside the gauge. |

## How the numbers behave

- **Pooled reading.** The pooled reading is the plain mean of each account's used share,
  so it matches the pool's real capacity only when the plans are the same size.
- **Idle accounts.** The proxy learns quota only from real requests, so an idle account
  keeps its last observation. A window whose reset time has passed counts as empty
  again. The panel marks readings older than an hour.
- **Exhausted windows.** A Claude window the upstream reports as `rejected` counts as
  full, and Claude utilization above 100% is capped at 100%.

## Security

- **Pause on rejection.** CLIProxyAPI bans an IP for 30 minutes after five rejected
  management keys. When the proxy rejects the key, the poller stops until you refresh
  manually or change a setting, so a wrong key does not lock localhost out.
- **Key handling.** The key is read from `key_file` on each poll and sent only in the
  `X-Management-Key` header to `base_url`. Error messages never include response bodies.

## IPC

```sh
noctalia msg plugin subsy/cliproxy-usage:poller all refresh
noctalia msg panel-toggle subsy/cliproxy-usage:panel
```

## Tests

```sh
lua tests/shared_test.lua
noctalia plugins lint .
```

## License

MIT
