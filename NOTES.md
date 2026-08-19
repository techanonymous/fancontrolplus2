# Dev notes — FanControl Plus 2

Working journal for this fork. Not shipped to users; the user-facing docs are in
[README.md](README.md).

---

## Where things stand (2026-08-19)

**Released and live.** Latest is `2026.08.19g`, installed and running on unraid99.
Fifteen releases across two days — the tail of that list is a bug-fix train, see
section 9. Everything is pushed; `git log v2026.08.19g..HEAD` is empty.

Repo: <https://github.com/techanonymous/fancontrolplus2> — MIT licensed, described,
topic-tagged, and no longer naming the upstream author anywhere user-facing (that
attribution lives in `LICENSE`, `NOTICE` and the GitHub README).

### Running on unraid99

Five fan configs, five control loops, plus `array_monitor` and the dashboard updater:

| Config | Channel | Driven by |
|---|---|---|
| `CPU_Radiator_Intake` | pwm6 | IPMI CPU Temp |
| `Mobo_Rear_Exhaust` | pwm1 | IPMI |
| `Addin_cards` | pwm4 | SAS controller |
| `Drives_Mid` | pwm2 | Disk (10 disks) |
| `Drives_Rear_Exhaust` | pwm3 | Disk (10 disks) |

**The original FanCtrl Plus has been uninstalled**, so this is now the only fan
controller on that box. Worth knowing: its removal script runs `pkill -f
array_monitor.sh` *unqualified*, which matches ours too — it happened not to kill
ours, but a future uninstall of anything sharing that script name could.

### Plan status

| Step | Status |
|---|---|
| Tier 1 — security + correctness | **done** — `2026.08.18` |
| Tier 3 — hysteresis, asymmetric slew, seconds interval | **done** — `2026.08.18c` |
| Loose end — chart crosshair for four sources | **done** — `2026.08.19g` |
| Tier 2 — 2-segment piecewise curve | **deferred**, see section 8 |
| Loose end — older storcli (`ROC temperature`) path | **still unverified** |

## 1. The rename

Plugin identity went `fanctrlplus` → `fancontrolplus2` throughout, so this installs
*beside* the original instead of over it (two Unraid plugins sharing install dirs
cannot coexist — the second wins).

| | Now |
|---|---|
| Install dirs | `/boot/config/plugins/fancontrolplus2`, `/usr/local/emhttp/plugins/fancontrolplus2` |
| Service | `/etc/rc.d/rc.fancontrolplus2` |
| Runtime state | `/var/run/fancontrolplus2*`, `/var/tmp/fancontrolplus2/`, `/var/log/fancontrolplus2*` |
| Display name | FanControl Plus 2 |
| Author / support | `techanonymous` / this repo's issues |

**Deliberately left on upstream names** so `git merge upstream/main` stays workable:

- the `fcp-` / `fanctrl-` CSS class prefixes
- the `Fanctrl*.php` / `Fcp*.php` include filenames

Both are scoped to the plugin's own directory so they don't collide. The coexistence
risk noted here **did** materialise, and not cosmetically: see section 9, the
Dashboard `setTempCell` collision. Fixed by scoping the tile script, which is the
right defence regardless of whether both plugins are installed.

---

## 2. IPMI + SAS temperature sources

Four sources now: Disk, CPU, IPMI, SAS. Each computes a PWM from its own linear
low→high ramp; the highest wins. Disk stays the tiebreak winner on equal PWM, which
preserves the original two-source behaviour exactly.

### Architecture

Disk and CPU read hwmon/smartctl directly. IPMI and SAS cannot — they shell out:

| Source | Tool | Cost | Comes from |
|---|---|---|---|
| IPMI | `/usr/sbin/ipmi-sensors` (freeipmi) | ~70 ms | Unraid **IPMI Tools** plugin |
| SAS | `storcli2 /cN show all` | ~380 ms | **HBAviewer** plugin (`/opt/MegaRAID/storcli2/`) |

Every fan config runs its own loop process, so N fans ticking together would mean N
calls at the same BMC/HBA. Hence [scripts/fcp2_sensor_sources.sh](scripts/fcp2_sensor_sources.sh):
a shared cache in `/var/tmp/fancontrolplus2/`, refreshed under `flock`, with a
re-check after acquiring the lock. **TTLs follow the fan's interval** (period/2,
clamped to 3-20 s for IPMI and 4-30 s for SAS) so a fan is never served a reading
left over from its own previous cycle — the cache only coalesces *different* fans.
They were fixed at 20/30 s until Tier 3 introduced second-based intervals, which
would have broken that guarantee below a 60 s period.

`Common.php` reads the same cache through `bash -c source`, so the settings page
does not poll independently: ~20 ms warm, ~450 ms cold.

**Dependency stance (decided):** depend on the plugins, don't bundle. If the tool
isn't there the whole UI section is not rendered — no half-broken options. Rationale
was simply that without the plugin the readings wouldn't work anyway.

### Details that are easy to get wrong

- **`N/A` must not become 0.** Two of cube's IPMI sensors (M2_SSD1/M2_SSD2) read the
  literal string `N/A`. Coerced to 0 that reads as "cold" and drives fans *down*.
  Both the reader and the dropdown builder treat it as unreadable.
- **IPMI record IDs can be renumbered by a BMC firmware update.** The cfg stores
  `ipmi_sensor` (record id) *and* `ipmi_sensor_name`; if the ID's name no longer
  matches, the sensor is re-resolved by name.
- **SAS defaults are 55/80 °C, not disk-like 40/70.** The 9600-24i idles at ~52 °C
  chip. Board sits ~35 °C, so if you pick Board you must lower the range by hand.
- `fcp2_scale` guards the divide-by-zero that a `low == high` config would cause.
  (The pre-existing CPU/disk code still has that hole — untouched on purpose to keep
  the diff small. Worth fixing upstream-side someday.)

### New cfg keys

```
ipmi_enable  ipmi_sensor  ipmi_sensor_name  ipmi_min_temp  ipmi_max_temp
sas_enable   sas_ctrl     sas_probe         sas_min_temp   sas_max_temp
```

`sas_probe` is `chip` or `board`. The UI submits one combined `sas_sensor` value of
`"<ctrl>:<probe>"`; `update.fancontrolplus2.php` splits it on save.

### Files touched

| File | Role |
|---|---|
| `scripts/fcp2_sensor_sources.sh` | **new** — cached readers, `fcp2_scale` |
| `scripts/fancontrolplus2_loop.sh` | daemon: two new sources + N-way arbitration |
| `scripts/fancontrolplus2_refresh_single.sh` | same, for Run Now |
| `include/Common.php` | `detect_ipmi_sensors()`, `detect_sas_sensors()`, cache bridge |
| `include/FanBlockRender.php` | two new UI sections (self-hiding) |
| `include/update.fancontrolplus2.php` | parse + persist new keys |
| `include/FanctrlLogic.php` | newtemp defaults, render args |
| `fancontrolplus2.page` | sensor lists, unit inputs, enable-toggle JS, dirty tracking |
| `include/chart-handler.js` | new curves + generalised footer note |
| `css/fcp.base.css` | `.fcp-src-input` / `.fcp-src-label` alongside `.cpu-*` |

Note `detect_cpu_sensors()` is (upstream's doing) **nested inside**
`list_valid_disks_by_id()` in `Common.php`, so it only exists after that function has
been called once. The new detectors are top-level — don't accidentally nest them.

### Test results (unraid99, live hardware)

| Case | Result |
|---|---|
| IPMI alone, CPU Temp 44 °C, range 30–60 | PWM 173, `Temp=44°C (IPMI)` |
| SAS alone, chip 52 °C, range 40–70 | PWM 163, `Temp=52°C (SAS)` |
| Both, SAS hotter within its range | PWM 193, SAS wins |
| IPMI sensor reading `N/A` | falls through to Idle, not 0 °C |
| All new sources off | unchanged Idle behaviour (regression) |
| Wrong record id + valid name | re-resolved by name |
| `detect_ipmi_sensors()` | 10 sensors, 74 ms (2 `N/A` correctly excluded) |
| `detect_sas_sensors()` | 2 entries, 376 ms cold / 20 ms warm |

---

## 3. Target hardware — unraid99 (cube, Supermicro H12SSL-i)

- **The only PWM outputs are the Corsair Commander Pro** (`corsaircpro`, hwmon6,
  6 channels + 6 tachs). The H12SSL-i exposes no super-I/O hwmon chip, so there are
  no motherboard PWM channels for the plugin to drive at all.
- IPMI *does* report fan sensors (FAN1–5, FANA/B; only FAN5 reads, 2520 RPM) but they
  are read-only. Driving them would need Supermicro OEM `ipmi-raw` commands — a
  separate and much riskier project. The IPMI Tools plugin's own `ipmifan`/`ipmi2json`
  scripts are **ASRock-only** and won't help here.
- SAS controller is a Broadcom **eHBA 9600-24i Tri-Mode** (`mpi3mr`), controller index
  0, chip ~52–61 °C, board ~35–41 °C.
- Available IPMI temp sensors: CPU, System, Peripheral, CPU_VRM, SOC_VRM, VRMABCD,
  VRMEFGH, P1_DIMMA~D, P1_DIMME~H, AOC_NIC4. (M2_SSD1/M2_SSD2 report `N/A`.)

So on this box the fork's work is entirely **sensor-side**: read board/VRM/DIMM/HBA
temps, drive the Commander Pro through hwmon as before.

---

## 4. Open decisions — for tomorrow

1. ~~Push to `origin/main`?~~ **Done** — pushed 2026-08-18. Note that LICENSE must stay
   verbatim MIT or GitHub reclassifies the repo as "Other"; the provenance disclosure
   lives in `NOTICE` for exactly that reason.
2. **Version + release.** The `.plg` still carries upstream's `&version; 1.3.3` and
   upstream's `&MD5;`, while its `<URL>` now points at `techanonymous/fancontrolplus2`
   releases that don't exist — so `plugin install` cannot work yet. Needs a version
   bump, a built `.txz`, and a GitHub release. Standing rule: **don't tag or publish
   without explicit say-so.**
3. **How to build the `.txz`.** Must be built on Linux, not the Windows checkout.
   A `.gitattributes` now pins `*.sh`/`*.php`/`*.page`/`*.plg` to LF precisely because
   `core.autocrlf=true` would otherwise ship `#!/bin/bash\r` and fail on Unraid.
4. **Chart live-crosshair.** The preview draws the new IPMI/SAS curves and the footer
   lists all active rules, but the moving current-temperature marker in
   `chart-handler.js` still only tracks Disk and CPU — it looks datasets up by label
   and needs reworking for four sources.
5. **Older storcli (SAS2/SAS3) path is unverified.** The `ROC temperature` fallback
   parse is two lines of awk, marked in the code. Relevant to unraid3, which has
   `lsiutil.plg` and an older controller. Untestable on cube.
6. **Upstream still has no LICENSE file.** The MIT grant in `LICENSE` is scoped to this
   fork's changes only, with the position spelled out in `NOTICE`, which also offers to
   change licensing or take the fork down at ck9393's request. Worth telling him the
   fork exists rather than waiting for him to find it.
7. **Donate links still point at ck9393** (correct — he's the original author), with
   `DonateText` reworded to say so. Change only if you'd rather drop them entirely.
8. **CSS prefix sweep** (`fcp-` → something unique) — only needed if you ever want
   both plugins installed side by side with both Dashboard tiles rendering.

## 5. Dev loop reminder

`/usr/local/emhttp/plugins/<name>/` is **RAM** on Unraid, rebuilt from the `.txz` each
boot — so rsyncing straight into the live tree is a free, reversible dev loop and a
reboot restores stock. No need to go through the `.plg` at all while iterating.

---

## 6. Reviewed: javi-dev/fanctrlplus (2026-08-18)

Another fork of upstream — 37 commits ahead, 0 behind, last pushed 2026-06-14, no
LICENSE. Focus: noise reduction, modern UI, security hardening.

**Decision: cherry-pick, do not rebase onto it.** It keeps the `fanctrlplus` identity
and overwrites the original (our coexistence rename would have to be redone), and its
UI rewrite is the expensive half with the least payoff for us.

### Worth taking

1. **Security hardening — do this regardless.** Upstream's `identify` endpoint does
   `if (is_file($pwm))` then writes `0`/`255` to that path: an arbitrary-file-write from
   a GET parameter. **Our fork inherits it** (`include/FanctrlLogic.php`, `case 'identify'`).
   Javi added a `^/sys/devices/.+/pwm\d+$` whitelist. Bundle also has: `display_errors`→0,
   `LOCK_EX` on all 9 `file_put_contents` (we have none), `escapeshellarg` on the logger
   call in `Common.php::log_migrate`, config-filename validation on `delete`/`setsyslog`,
   and a `parse_ini_file === false` guard.
2. Divide-by-zero guards on the CPU and disk curves (we only guarded the new sources).
3. `log_enable` read once at startup instead of a `grep` every cycle.
4. **2-segment piecewise curve** (`mid_temp`/`mid_pwm`) — good idea, see flaws below.

### Two real bugs in their implementation — do not copy verbatim

- **Hysteresis defeats the ramp.** The 2°C hysteresis check `continue`s *before* the PWM
  ramp block, so once the ramp has been step-capped and temperature stabilises, PWM never
  converges. Simulated: target 209, fan parks at 152 indefinitely under steady load.
  Fixable in ~3 lines (only skip when `prev_pwm` already equals target).
- **Piecewise defaults silently change existing curves.** `mid_temp="${mid_temp:-43}"` /
  `mid_pwm="${mid_pwm:-100}"` apply to configs that predate the feature. With a 40% min
  (PWM 102), `mid_pwm=100` sits *below* minimum so segment 1 ramps downward.

Also: their piecewise is applied to the **disk branch only** — CPU is still single-linear.
Our `fcp2_scale` is the better home for it: implement once, all four sources get it.

### UI verdict — Tier 4 dropped

Built a look-only preview on unraid99 (staged as plugin `fcpuipreview`, own config dir,
no scripts, Identify guarded) and Alex compared it against the live plugin. Verdict: no
visible improvement beyond the midpoint fields, fonts render small, light mode looks bad.

Cause of the font issue: their CSS mixes two sizing systems — `--fcp-font-size: 0.9rem`
resolving off the 16px browser root, alongside leftover hardcoded `13px`/`12px`/`16px`/
`20px` rules. Nothing inherits from the Unraid theme. Their dark mode is the path they
actually designed against; light themes (white/azure) get untuned `:root` defaults.

**So: skip the 1,141-line `fcp.base.css` rewrite and the `chart-handler.js` rewrite.**
Preview has been torn down; nothing remains on unraid99.

The `javi` git remote is still configured locally for cherry-picking Tiers 1–3.

---

## 7. How to build a release

The `.txz` must be built on Linux (unraid99 is fine). `git archive HEAD` is the
source of truth — it honours `.gitattributes`, so the payload is LF regardless of
the CRLF working tree on Windows.

**The packaged `README.md` is not the project README.** `ShowPlugins.php` renders the
whole of `plugins/<name>/README.md` through Markdown into the Plugins-page description
cell, with no truncation - so the build copies `unraid/plugin-README.md` in as
`README.md` instead. Shipping the project README made that row enormous (fixed in
2026.08.18a).

Package layout mirrors upstream's: `install/doinst.sh` plus
`usr/local/emhttp/plugins/fancontrolplus2/`. `doinst.sh` chmods the scripts and
symlinks `rc.fancontrolplus2` into `/etc/rc.d/`. Excluded from the payload:
`NOTES.md`, `unraid/`, `ca_profile.xml`, `FanControlPlus2.xml`, `deprecated/`,
`.gitattributes`.

Sequence, which matters:

1. Bump `<!ENTITY version>` in `unraid/fancontrolplus2.plg` and add a `###<version>`
   CHANGES entry.
2. Build the `.txz` from `git archive HEAD`.
3. Take the md5 of the built file and put it in `<!ENTITY MD5>`.
4. Commit, push, then `gh release create v<version>` with the `.txz` attached.

The tag must be `v<version>` and the asset must be named
`fancontrolplus2-<version>.txz`, because the `.plg` `<URL>` is built from the
`&version;` entity. Get either wrong and Unraid downloads a 404.

`&MD5;` is a gate, not a checksum for show: if it does not match the file already on
the flash, the `.plg` deletes it and re-downloads. See [[unraid-plugin-lifecycle]].

Version numbers are date-based (`YYYY.MM.DD`). Upstream uses semver (1.3.3) and this
is a different plugin name, so there is no comparison between the two.

---

## 8. Tier 3 as built, and why Tier 2 got deferred

### The anti-oscillation design

Two independent mechanisms, both per-fan configurable:

- **Hysteresis** (`hysteresis`, default 2 °C) gates whether a *new target* is computed:
  only when the temperature has moved that far from the temperature last acted on.
- **Asymmetric slew** (`slew_down` default 8 PWM/tick, `slew_up` default 0 = unlimited)
  gates how fast the fan may *approach* that target. Up is never limited, so a real
  thermal event is answered immediately; down glides.

**The separation is the whole point.** javi's version returns early from the entire
cycle when hysteresis trips, so once its ramp has been step-capped and the temperature
settles, the fan parks short of target indefinitely. Verified here on real hardware that
a fan still ramps on a tick where the temperature has not changed at all.

**`intended_pwm` is tracked separately from the value actually written**, so steps
smaller than the 5-PWM write threshold accumulate rather than being discarded. Without
this, any slew smaller than the threshold silently stalls the fan wherever it got to —
measured that directly: a 4 PWM/tick limit left the fan stuck at 93% forever.

### Measurements that drove the design

VRM/DIMM curve (20–100% over 45–70 °C) at 10s polling, 5-minute trace:

| strategy | changes | fan movement | lag to full speed |
|---|---|---|---|
| raw | 29 | 187% | 30s |
| EMA smoothing (N=4) | 17 | 96% | **60s** |
| slew only | 27 | 132% | 30s |
| **hysteresis 2 °C + slew down 8** | **11** | **73%** | **30s** |

**EMA / low-pass smoothing was rejected**: it costs 30s of lag and does not even beat
hysteresis on change count. It delays everything equally, including the rise that short
intervals exist to catch. Hysteresis filters only jitter.

### Curve steepness matters more than any of this

`Drives_mid` was `low=38 high=45` — a 7 °C span, and `smartctl` reports whole degrees,
so only 8 speeds are reachable and **each 1 °C is a 13% jump**. Widening a range is the
cheapest smoothing available and needs no code: `35–55` makes each degree ~4.5%.

### Why Tier 2 (piecewise curve) is deferred

Its purpose was noise reduction, and Tier 3 plus a wider range addresses that more
directly. It is still worth doing for the "quiet below X, aggressive above X" shape, but
it is no longer urgent. When it happens it belongs in `fcp2_scale`, so all four sources
get it — javi's is disk-only — and the midpoint must default to the linear midpoint so
existing configs are unchanged unless deliberately altered.

---

## 9. The 2026-08-19 bug-fix train, and what it should teach the next change

Fifteen releases in two days. Tier 1 and Tier 3 were the planned work; almost
everything after `2026.08.18` was fallout found by actually installing and using it.
The pattern worth remembering is that **none of these were caught by linting, and
several were invisible rather than loud**.

### Failures that looked like success

| Symptom | Cause |
|---|---|
| Plugins page said "up-to-date" forever | A bare `&` in the changelog made the `.plg` invalid XML, so `plugin("version")` returned `false` and `strcmp("", installed)` is negative. **Nothing in the UI hints at a parse failure.** |
| Same again, nearly | `&mdash;` — XML predefines only `amp lt gt quot apos`; every other named entity must be in the DTD. Caught pre-publish by the entity audit. |
| Settings page blank | The `.page` rename changed the route; stale browser tabs and bookmarks hit a name the dispatcher can't resolve, and Unraid renders the shell with no content and no error. |
| Dashboard temperature column blank | Both plugins declared a global `setTempCell()`; the last script parsed won. RPM/Status kept working because they are set inline, which is what made it look like a data problem rather than a collision. |
| Chart said "No runtime data yet" | Its parser accepted only `(CPU|Disk)` origins, so the `(IPMI)`/`(SAS)` values the daemon writes were discarded. |

### The same constraint enforced in four places

"Fan Speed on Idle" was capped at the Min speed by the browser's submit check, the
save handler, the daemon, **and** a live keystroke handler. Removing three of them
looked like a fix and changed nothing, because the fourth rewrote the field before
the value ever reached them. When a constraint turns out to be enforced twice, assume
it is enforced four times and go looking.

### Windows checkouts are case-insensitive

Writing the redirect shim as `fancontrolplus2.page` silently **overwrote**
`FanControlPlus2.page` — same file on Windows — replacing the 1924-line settings page
with a 25-line stub, which was then committed. The shim now lives at
`unraid/legacy-route.page` and is renamed by the build. Any future file whose name
differs from an existing one only by case must be handled the same way.

### Build guards now in place

The build refuses to produce a package unless all of these hold. Each exists because
the corresponding thing actually shipped broken, or nearly did:

- the `.plg` parses via Unraid's own `plugin()` helper **and** reports the expected version
- no named entity in the `.plg` outside XML's five predefined ones and the DTD's own
- `FanControlPlus2.page` is > 1000 lines, the shim < 60 (catches the case-collision clobber)
- the shim carries no `Menu=` key (or it re-appears in Settings and undoes the sort fix)
- every Dashboard tile script opens with an IIFE and closes it (no global leakage)
- `stripUnit` handles the `s` suffix, and no stale minutes-era validation text remains
- all four idle caps are absent
- the packaged `README.md` is <= 4 lines and <= 400 bytes (it *is* the Plugins-page row)
- `chart-handler.js` no longer hardcodes `(CPU|Disk)` origins
- no CRLF in any shipped script, PHP or page

### Release procedure reminder

Ordering matters: bump `<!ENTITY version>` and add the `###<version>` CHANGES entry,
build from `git archive HEAD`, take the md5 of the built file into `<!ENTITY MD5>`,
then push and `gh release create v<version>` with the asset named
`fancontrolplus2-<version>.txz`. The tag and asset name are both derived from the
version entity — get either wrong and Unraid downloads a 404.

`gh release create` does not work on this workstation (see the toolchain-gaps memory);
use the REST API. And `raw.githubusercontent.com` caches for a few minutes, so a check
straight after publishing can act on a stale `.plg` — clear `/tmp/plugins/<name>.plg`
and re-run `plugin check` before concluding anything.
