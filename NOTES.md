# Dev notes — FanControl Plus 2

Working journal for this fork. Not shipped to users; the user-facing docs are in
[README.md](README.md).

---

## Where things stand (2026-08-18)

All work is **pushed to `origin/main`**. The repo is public at
<https://github.com/techanonymous/fancontrolplus2>, MIT licensed (and detected as MIT
by GitHub), with description and topics set.

| Commit | What |
|---|---|
| `6e95703` | Rebrand fork as fancontrolplus2 |
| `467e23a` | Add IPMI and SAS controller temperature sources |
| `f8f7abf` | Add dev notes / working journal |
| `535bbea` | Add MIT licence and rewrite project docs for the fork |
| `ff1bcd0` | Keep LICENSE as verbatim MIT, move provenance to NOTICE |

Nothing is installed on any server. The feature was tested on unraid99 with staged
copies in `/tmp` and a fake PWM target, and every artifact was removed afterwards —
`/usr/local/emhttp/plugins/fancontrolplus2`, `/boot/config/plugins/fancontrolplus2`
and `/var/tmp/fancontrolplus2` are all absent on that box.

---

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

Both are scoped to the plugin's own directory so they don't collide. The only
exposure is cosmetic CSS bleed *if both plugins are installed at once* and their
Dashboard tiles render on the same page. Deferred until that actually matters.

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
re-check after acquiring the lock. TTLs (IPMI 20 s, SAS 30 s) are deliberately
shorter than the 1-minute minimum interval, so a fan is never served a reading left
over from its own previous cycle — the cache only coalesces *different* fans.

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
