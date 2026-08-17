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
- Uses a linear control algorithm to smoothly adjust fan speed (PWM) based on the current temperature (disk or CPU) between your defined low/high values
- Identify and label PWM controllers to match physical fans easily
- Dashboard tile and system integration
- Optional FCP Airflow Dashboard tile, similar to Unraid’s built-in Airflow tile but enhanced with support for custom fan labels
- Drag and drop fan configuration boxes to reorder them as you like. The new order is saved and reflected in both the UI and Dashboard.

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

