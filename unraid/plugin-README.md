**FanControl Plus 2** — automatic fan speed control driven by disk, CPU, IPMI baseboard
and SAS/HBA controller temperatures. When several sources are enabled, the fan runs at the
highest speed any of them asks for.

IPMI sensors need the *IPMI Tools* plugin; SAS controller temperature needs *HBAviewer*
for StorCLI2. Both are optional — without them those sections are simply hidden.

A fork of [FanCtrl Plus](https://github.com/ck9393/fanctrlplus) by ck9393, who wrote
essentially all of it. Installs alongside the original rather than replacing it.
