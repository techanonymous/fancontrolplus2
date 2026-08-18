# **FanControl Plus 2**

Automatic fan speed control for Unraid, driven by disk, CPU, IPMI and SAS controller
temperatures.

> ### A fork — original credit
>
> This is a fork of **[FanCtrl Plus](https://github.com/ck9393/fanctrlplus)**, created and
> maintained by **[ck9393](https://github.com/ck9393)**. Essentially all of the plugin —
> the control daemon, the web UI, the dashboard tiles, the disk and CPU temperature
> handling — is his work, and all credit for it belongs to him.
>
> This fork exists only to add two extra temperature sources (IPMI and SAS/HBA) and is
> renamed throughout so that it installs *alongside* the original rather than over it.
> If you don't need those sources, **install the original instead** — it is in Community
> Apps, actively maintained, and supported on the
> [Unraid forums](https://forums.unraid.net/topic/191722-plugin-fancrtl-plus/).
>
> Please raise issues with this fork [here](https://github.com/techanonymous/fancontrolplus2/issues),
> not with ck9393.

Each fan configuration can monitor specific drives, the CPU, a baseboard (IPMI) sensor
and the SAS controller, define a temperature range, and scale fan speed automatically
using a linear control algorithm. When more than one source is enabled, the fan runs at
the highest speed any of them asks for. Configuration is done through a web UI, with
custom thresholds, intervals and labels available per fan.

---

## 🆕 What this fork adds

Everything else is unchanged from upstream v1.3.3.

| Addition | Detail |
|---|---|
| **IPMI temperature source** | Any readable baseboard sensor — VRM, DIMM, system inlet, chipset, NIC — selectable per fan with its own low/high range |
| **SAS/HBA temperature source** | Controller chip or board temperature, selectable per fan with its own range |
| **Four-way arbitration** | Disk, CPU, IPMI and SAS each compute a target PWM; the highest wins |
| **Shared reading cache** | Both new sources are cached under `flock` in `/var/tmp/fancontrolplus2/`, so many fan configs don't each hammer the BMC or HBA |
| **Renamed plugin identity** | Installs beside the original instead of replacing it |

Design notes, test results and the reasoning behind the caching live in
[NOTES.md](NOTES.md).

---

## 📦 Requirements and dependencies

**Required:** Unraid 6.9.0 or newer. Nothing else — the disk and CPU sources work out of
the box, exactly as upstream.

**Optional**, and only needed for the sources this fork adds:

| For | You need | Provides | If missing |
|---|---|---|---|
| IPMI sensors | [**IPMI Tools**](https://forums.unraid.net/topic/44650-plugin-ipmi-tools/) plugin | `/usr/sbin/ipmi-sensors` (freeipmi) | The IPMI section is not shown in the fan config UI |
| SAS controller | [**HBAviewer**](https://github.com/techanonymous/Unraid-HBAviewer-sas4) plugin | StorCLI2 in `/opt/MegaRAID/storcli2/` | The SAS section is not shown in the fan config UI |

Neither dependency is bundled, and neither is required. If the tool isn't present the
whole section is simply not rendered — there are no half-working options to trip over.

Notes on the IPMI path specifically:

- It uses **freeipmi's `ipmi-sensors`**, not `ipmitool`.
- Access is **in-band** via `/dev/ipmi0`, so no BMC address, username or password is
  ever configured or stored.
- Sensors reporting `N/A` (a header with nothing attached) are excluded from the
  dropdown and are never treated as 0°C.
- Record IDs are stored alongside the sensor **name**, because a BMC firmware update
  can renumber records; a mismatch is re-resolved by name.

Your motherboard must expose PWM channels through `hwmon` for the plugin to control
anything — that part is unchanged from upstream. Some server boards expose none, in
which case an add-in controller (for example a Corsair Commander Pro) provides them.

---

## ✨ Features

- Full-featured Web UI for configuration and monitoring
- Supports temporary fan configuration with safe validation and custom naming
- Automatically starts with the Unraid array for hands-free operation
- Set custom thresholds and intervals per fan
- Control multiple PWM fans independently
- Monitor temps from array disks, NVMe, unassigned devices, the CPU, IPMI baseboard
  sensors and the SAS controller
- Uses a linear control algorithm to smoothly adjust fan speed (PWM) based on the
  current temperature between your defined low/high values
- Identify and label PWM controllers to match physical fans easily
- Dashboard tile and system integration
- Optional FCP Airflow Dashboard tile, similar to Unraid's built-in Airflow tile but
  enhanced with support for custom fan labels
- Drag and drop fan configuration boxes to reorder them as you like. The new order is
  saved and reflected in both the UI and Dashboard.

---

## 🔧 Installation

This fork is **not** in Community Apps. Install it from *Plugins → Install Plugin*
using:

```
https://raw.githubusercontent.com/techanonymous/fancontrolplus2/main/unraid/fancontrolplus2.plg
```

Support / issues: <https://github.com/techanonymous/fancontrolplus2/issues>

---

## 📄 Licence

The changes made in this fork are released under the **MIT Licence** — see [LICENSE](LICENSE).

Upstream is published **without a licence file**, so no explicit terms were granted for
the original code. The MIT grant covers this fork's contributions only; the original
portions remain ck9393's work under whatever terms he chooses, and nothing here purports
to relicense them. The full position is in [NOTICE](NOTICE).

---

## ☕ Support the original author

If you find this plugin useful, the person to thank is **ck9393** — this fork is a thin
layer on top of his work.

<p align="left">
  <a href="https://www.paypal.com/paypalme/cck9393" target="_blank">
    <img src="https://raw.githubusercontent.com/techanonymous/fancontrolplus2/main/.github/assets/donate.png" alt="Donate" width="90">
  </a>
</p>
