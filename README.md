# Hawk for Omarchy

Your [Hawk](https://hawkish.app) vault, sitting in the bar behind the Hawk
mark: account value and today's realized P&L. Click it and the panel shows what the console shows —
the daily realized P&L calendar with its Today / 7d / 15d / 30d roll-ups and
win/loss record, and the position-value chart with its range picker and
high-water mark.

The bar entry turns red with a `⏸` when the bot is paused and a `⚠` when the
bot has not synced for 15 minutes. With notifications on, every closing fill
lands as a desktop toast with the Hawk logo (`JUP +$1.56 · Closed at
$0.2271`), and so do pause/resume and a stale sync — a watchdog you notice without opening
Telegram.

## Where the numbers come from

Nothing here needs a login, a key, or SSH. Three public sources:

- **Hyperliquid's info API**, keyed by the vault's agent wallet address:
  account value, margin, open positions, and today's fills for the live
  figure. The wallet holds the whole vault, so every dollar figure is scaled
  by your share of it — the header, the position chips, the toasts, the
  calendar and the chart all describe the same money. Fills are paginated forward from UTC midnight and de-duplicated,
  because a bare `userFills` call is a sliding 2000-fill window.
- **The vault's public Convex query** (`vaults:getVaultPublicView`): label,
  leverage, paused, cycles, your share count and fraction, and the sync age.
- **The console's own calendar and chart queries**
  (`dailyPnlQuery:listDailyRealized`, `vaults:getNavSeries`), so the cells and
  the curve are the console's rows, scaled by your share of the vault, not a
  recomputation.

The calendar's current-day cell is refreshed by a Convex cron and can lag by
a few minutes; the header's **TODAY · LIVE** figure is summed from fills as
they land. They are labeled separately on purpose.

## Installing

```bash
omarchy plugin add https://github.com/oliverox/omarchy-hawk
omarchy plugin enable oliverox.hawk --section right
```

Hacking on it: the shell watches `~/.config/omarchy/plugins/<id>/` for
changes but does not follow a symlink there, and a changed `Panel.qml` only
takes effect after `omarchy restart shell` (Qt keeps the compiled component
cached). Script changes apply on the next refresh.

Settings live in the widget's entry in `~/.config/omarchy/shell.json`:

| key      | default  | what it does                                 |
|----------|----------|----------------------------------------------|
| `slug`   | `hawk-2` | which vault to show                          |
| `notify` | `true`   | toasts for closing fills, pause, stale sync  |

Refresh cadence: the account line every minute; the chart on panel open and
every five minutes while it is open. Press `r` in the panel to refresh, `←`
`→` to change the chart range, `Esc` to close.

## Requirements

- Omarchy Quattro (4.x)
- `jq` and `curl` (standard on Omarchy)
- `notify-send` for toasts (standard on Omarchy)

## The script on its own

`bin/hawk-status` works without the panel. Everything comes out as JSON:

```bash
bin/hawk-status status
bin/hawk-status summary
bin/hawk-status nav 30d        # 1d 7d 15d 30d 60d 90d all
bin/hawk-status demo on        # invented data, for screenshots
HAWK_SLUG=hawk-1 bin/hawk-status summary
```

`HAWK_WALLET` overrides the wallet the vault policy names, `HAWK_HWM` the
high-water mark per share for the chart line (default 1), `HAWK_DAYS` the
calendar length (1–400 days, default 70). The two API origins are fixed;
`HAWK_CONVEX_BASE` and `HAWK_HL_BASE` accept only a loopback `http://127.0.0.1:PORT`
mock, which is what `tests/run` uses.

The script runs `/usr/bin` tools only, with curl limited to HTTPS, no
redirects, a 15 s timeout and a 4 MiB cap per answer (larger ones are refused,
not cut). The panel kills it if it prints more than 256 KiB or runs past two
minutes.

## Removing it

```bash
omarchy plugin remove oliverox.hawk
```

Two small directories stay behind, both 0700, and nothing else:

- `~/.cache/omarchy-hawk/fills-seen.json`: the time of the newest fill already
  toasted, so a reinstall doesn't announce old exits.
- `~/.config/omarchy-hawk/demo`: only if you turned demo mode on.

Delete those two files yourself if you want them gone.

## Tests

```bash
tests/run
```

Runs the real script against a local mock of both APIs with fixture data:
formatting, the calendar roll-ups, the win/loss record, fill pagination, the
first-look toast silence, chart scaling, demo mode and input validation, plus
the hardening: an oversized streamed answer is refused, a symlink planted on the
cache file is replaced rather than written through, and a `curl` early on `PATH`
is never run.

## Licence

MIT
