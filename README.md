# **FanControl Plus 2**

> A fork of [**FanCtrl Plus**](https://github.com/ck9393/fanctrlplus) by [ck9393](https://github.com/ck9393),
> renamed so it installs alongside the original rather than over it.
> The goal of the fork is to add **IPMI sensors** as a temperature source, next to the
> existing drive and CPU (k10temp) sensors. All credit for the original plugin goes to ck9393.

**FanControl Plus 2** is an Unraid plugin that provides automatic fan control based on the temperatures of HDDs, NVMe drives, Unassigned Devices, and optionally the CPU.  
Each fan configuration can monitor specific drives or the CPU, define a temperature range, and scale fan speed automatically using a linear control algorithm.  
Configuration is done through a user-friendly interface, with custom thresholds, intervals, and labels available per fan.

## ✨ Features

- Full-featured Web UI for configuration and monitoring
- Supports temporary fan configuration with safe validation and custom naming
- Automatically starts with the Unraid array for hands-free operation
- Set custom thresholds and intervals per fan
- Control multiple PWM fans independently
- Monitor temps from array disks, NVMe, unassigned devices, and optionally the CPU
- **New in this fork:** IPMI baseboard sensors (VRM, DIMM, system inlet, …) and SAS/HBA controller temperature as additional per-fan sources
- Uses a linear control algorithm to smoothly adjust fan speed (PWM) based on the current temperature between your defined low/high values; when several sources are enabled the fan runs at the highest PWM any of them asks for
- Identify and label PWM controllers to match physical fans easily
- Dashboard tile and system integration
- Optional FCP Airflow Dashboard tile, similar to Unraid’s built-in Airflow tile but enhanced with support for custom fan labels
- Drag and drop fan configuration boxes to reorder them as you like. The new order is saved and reflected in both the UI and Dashboard.

---

## 🌡️ IPMI and SAS temperature sources

Both are **optional and self-hiding**: if the tool that reads them is not installed,
the section simply does not appear in the fan configuration UI.

| Source | Needs | Read via |
|---|---|---|
| IPMI baseboard sensors | [Unraid IPMI Tools plugin](https://forums.unraid.net/topic/44650-plugin-ipmi-tools/) | `/usr/sbin/ipmi-sensors` (freeipmi), in-band over `/dev/ipmi0` — no BMC address or credentials |
| SAS/HBA controller | StorCLI2, as installed by the HBAviewer plugin | `storcli2 /cN show all` → chip and board temperature |

Sensors that read `N/A` (a header with nothing attached) are excluded from the
dropdown and never treated as 0°C.

Both tools are far slower than a hwmon read — roughly 70 ms and 380 ms per call —
and every fan configuration runs its own control loop, so readings are cached in
`/var/tmp/fancontrolplus2/` and refreshed under `flock`. Only the first process to
find the cache stale pays for the call; the rest read the file. The settings page
reads the same cache, so it does not add its own polling.

IPMI record IDs are stored alongside the sensor **name**, because a BMC firmware
update can renumber the records — if the ID no longer matches the stored name, the
sensor is re-resolved by name.

---

## 🔧 Manual Installation

**FanControl Plus 2** is not in Community Apps. Install it from *Plugins → Install Plugin* using:

```
https://raw.githubusercontent.com/techanonymous/fancontrolplus2/main/unraid/fancontrolplus2.plg
```

Support / Issues
- https://github.com/techanonymous/fancontrolplus2/issues

For the original plugin, see [ck9393/fanctrlplus](https://github.com/ck9393/fanctrlplus) and its
[Unraid forum thread](https://forums.unraid.net/topic/191722-plugin-fancrtl-plus/).

- If you find the original plugin helpful, consider buying **ck9393** a coffee!

<p align="left">
  <a href="https://www.paypal.com/paypalme/cck9393" target="_blank">
    <img src="https://raw.githubusercontent.com/techanonymous/fancontrolplus2/main/.github/assets/donate.png" alt="Donate" width="90">
  </a>
</p>

