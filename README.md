# Parcel Tracker for Omarchy

Track physical parcel deliveries (USPS, UPS, FedEx, DHL, Royal Mail, China
Post, Amazon Logistics, and more) from the Omarchy bar. Built for Omarchy
Quattro's shell plugin system.

```
omarchy plugin add https://github.com/johnl404/omarchy-parcel-tracker.git --enable
```

## Usage

The bar shows a box glyph with the number of parcels still in play. It
lights up when something needs attention (out for delivery, exception). Click
to open the panel:

- **Add** — paste a tracking number; the format is recognized and likely
  carriers are suggested (S10/UPU codes resolve to the origin country's
  postal operator). Override the suggestion, add an optional description.
- **Refresh** — per-parcel and refresh-all buttons are rate-limited per
  provider; buttons grey out with a countdown when the limit doesn't allow
  another attempt yet.
- **Detail** — full event timeline, description editing, deep link to the
  carrier's own tracking page, delete (click twice to confirm).
- **Settings** — notifications on/off, opt-in automatic updates, delivered
  archive duration.

Keyboard: `Esc` steps back or closes, `Enter` advances the add flow.

## Privacy

This plugin is built privacy-first:

- **Nothing leaves your machine by default.** Parcels, descriptions, and
  the API key (if you add one) live in a single local file:
  `~/.local/state/omarchy/plugins/parcel-tracker/packages.json`.
- **Deep links go to the carrier itself** — the UPS button opens ups.com and
  nowhere else.
- **Automatic updates are opt-in.** With automatic updates enabled, tracking
  queries go through 17track's official API using **your own** free API key.
  Understand the trade: 17track sees every tracking number you register
  through it (that is how their service works — they poll carriers for you).
  If that trade isn't worth it, leave automatic updates off and use the
  deep links.
- No analytics, no telemetry, no third-party requests of any other kind.

## Automatic updates (opt-in)

Direct scraping of carrier sites was tested and abandoned: UPS, USPS, FedEx,
and DHL all serve bot-wall challenges to automated clients (verified
2026-08). Rather than fighting that (and their ToS), automatic refresh uses
17track's official keyed API:

1. Create a free account at [api.17track.net](https://api.17track.net) and
   copy your API key (new accounts include a one-time free tracking quota).
2. Panel → Settings → enable *Automatic updates* and paste the key.

The plugin then polls conservatively: one request at a time, at most once an
hour per parcel (quota-friendly), with exponential backoff on failures
(2× per consecutive failure, capped at 4 hours). Desktop notifications fire
on out-for-delivery, delivered, exception, and returned transitions.

Carriers whose numbers can't be auto-refreshed without the aggregator still
work in manual mode: the detail view links straight to the carrier's site.

## Rate limits

| Provider | Min interval |
|---|---|
| S10 / national posts | 15 min |
| USPS, Evri, Yanwen, 4PX, SF Express | 15 min |
| UPS, FedEx, DHL, OnTrac, LaserShip, Purolator | 30 min |
| Amazon (deep link only) | 60 min |
| 17track aggregator (auto-updates) | 60 min |

Manual refresh goes through the exact same gate as the scheduler — the
button is disabled with a countdown when a parcel isn't due yet.

## IPC / keybinding

```sh
omarchy-shell shell toggle johnl404.parcel-tracker   # open/close the panel
omarchy-shell shell summon johnl404.parcel-tracker   # open
omarchy-shell shell hide johnl404.parcel-tracker     # close
omarchy-shell shell call johnl404.parcel-tracker refresh  # refresh all
```

Example Hyprland binding: `omarchy-shell shell toggle johnl404.parcel-tracker`.

## Recognized formats

- S10/UPU: two letters + nine digits + two-letter origin country (maps to
  ~55 national postal operators)
- UPS `1Z…`, FedEx 12/15/20-digit, USPS IMpb, DHL Express 10-digit,
  DHL eCommerce, Amazon `TBA…`, OnTrac, LaserShip, Evri, Yanwen, 4PX,
  SF Express, plus low-confidence guesses for bare digit runs (Purolator,
  DPD, GLS) offered as ranked alternatives.

## Development

```sh
omarchy plugin validate .
/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
node test/tracker.test.js
```

To run the plugin from this clone inside a live shell, symlink it into your
plugins directory:

```sh
ln -s "$PWD" ~/.config/omarchy/plugins/johnl404.parcel-tracker
```

To exercise the opt-in 17track fetch path without a real API key, run the
local mock (`python3 test/mock17track.py`) and temporarily point the two
`api.17track.net` URLs in `ProviderRegistry.js` at `http://127.0.0.1:8765`.

The provider registry (`ProviderRegistry.js`) is data-driven: adding a
carrier is one entry with patterns, a rate limit, a deep-link builder, and
optionally a fetch spec. Fetch specs expand into curl commands; `parse`
selects a response parser.

## Limitations

- Without the opt-in aggregator, tracking status only updates when you open
  the carrier page yourself (the plugin always deep links) — direct carrier
  endpoints block automated access as of August 2026.
- Amazon numbers have no public endpoint at all; deep link only.
- Event timestamps keep the carrier's local time (consistent within a
  parcel; 17track reports origin/destination local times).

## License

MIT — see `LICENSE`.
