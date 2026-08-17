#!/bin/bash
# fcp2_sensor_sources.sh - shared IPMI / SAS temperature sources.
#
# Sourced by fancontrolplus2_loop.sh (the per-fan daemon), by
# fancontrolplus2_refresh_single.sh (Run Now), and - via `bash -c source` -
# by Common.php when it builds the sensor dropdowns.
#
# WHY A CACHE: disk and CPU temperatures come from hwmon or smartctl, but
# these two sources have to shell out to an external tool, which costs three
# to four orders of magnitude more:
#
#   ipmi-sensors -t Temperature   ~70 ms
#   storcli2 /cN show all        ~380 ms  (per controller)
#
# Every fan config runs its own loop process, so N fans ticking on the same
# minute would mean N independent calls hitting the same BMC or HBA. Readings
# are cached in a shared file and refreshed under flock, so only the first
# process through the gate pays the cost and the rest read the file.
#
# The TTLs are shorter than the shortest configurable interval (1 minute), so
# a fan is never handed a reading left over from its own previous cycle - the
# cache only ever coalesces *different* fans that tick together.

FCP2_CACHE_DIR="/var/tmp/fancontrolplus2"
FCP2_IPMI_BIN="/usr/sbin/ipmi-sensors"
FCP2_IPMI_CACHE="$FCP2_CACHE_DIR/ipmi_temps"
FCP2_SAS_CACHE="$FCP2_CACHE_DIR/sas_temps"
FCP2_IPMI_TTL=20
FCP2_SAS_TTL=30

# ---------------------------------------------------------------- helpers

_fcp2_cache_fresh() {
  local f="$1" ttl="$2" mtime age
  [[ -s "$f" ]] || return 1
  mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
  age=$(( $(date +%s) - mtime ))
  (( age >= 0 && age < ttl ))
}

# fcp2_scale <temp> <low> <high> <min_pwm> <max_pwm>
# Linear ramp, matching the disk/CPU curve the plugin already uses. Guards
# the divide-by-zero that a low==high config would otherwise cause.
fcp2_scale() {
  local t="$1" lo="$2" hi="$3" pmin="$4" pmax="$5"
  (( hi <= lo )) && { echo "$pmax"; return 0; }
  if   (( t <= lo )); then echo "$pmin"
  elif (( t >= hi )); then echo "$pmax"
  else echo $(( pmin + (t - lo) * (pmax - pmin) / (hi - lo) ))
  fi
}

# ------------------------------------------------------------------- IPMI

# Needs the Unraid IPMI Tools plugin, which supplies /usr/sbin/ipmi-sensors
# (freeipmi - note this box has no `ipmitool`). Access is in-band over
# /dev/ipmi0, so no BMC address or credentials are involved.
fcp2_ipmi_available() {
  [[ -x "$FCP2_IPMI_BIN" && -e /dev/ipmi0 ]]
}

fcp2_ipmi_refresh() {
  fcp2_ipmi_available || return 1
  _fcp2_cache_fresh "$FCP2_IPMI_CACHE" "$FCP2_IPMI_TTL" && return 0

  mkdir -p "$FCP2_CACHE_DIR" 2>/dev/null
  local lock_fd
  exec {lock_fd}>"$FCP2_IPMI_CACHE.lock" || return 1
  flock "$lock_fd"
  # Re-check: another process may have refreshed while we waited on the lock.
  if ! _fcp2_cache_fresh "$FCP2_IPMI_CACHE" "$FCP2_IPMI_TTL"; then
    if "$FCP2_IPMI_BIN" --comma-separated-output --no-header-output \
         -t Temperature >"$FCP2_IPMI_CACHE.tmp" 2>/dev/null; then
      mv -f "$FCP2_IPMI_CACHE.tmp" "$FCP2_IPMI_CACHE"
    else
      rm -f "$FCP2_IPMI_CACHE.tmp"
    fi
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-

  [[ -s "$FCP2_IPMI_CACHE" ]]
}

# fcp2_ipmi_temp <record_id> [sensor_name]
# Prints whole degrees C, or returns non-zero if the sensor cannot be read.
fcp2_ipmi_temp() {
  local id="$1" name="$2" line got reading
  fcp2_ipmi_refresh || return 1

  # Record IDs are stable for a given board + BMC firmware, but a BMC
  # firmware update can renumber them. Trust the ID only while the name
  # still agrees; otherwise re-resolve by name.
  line=$(awk -F, -v id="$id" '$1 == id { print; exit }' "$FCP2_IPMI_CACHE")
  if [[ -n "$name" ]]; then
    got=$(printf '%s' "$line" | cut -d, -f2)
    if [[ "$got" != "$name" ]]; then
      line=$(awk -F, -v n="$name" '$2 == n { print; exit }' "$FCP2_IPMI_CACHE")
    fi
  fi
  [[ -n "$line" ]] || return 1

  reading=$(printf '%s' "$line" | cut -d, -f4)
  # A sensor with nothing attached reads the literal string 'N/A'. It must
  # not become 0 - that would look like "cold" and drive the fan *down*.
  [[ "$reading" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  printf '%.0f\n' "$reading"
}

# -------------------------------------------------------------------- SAS

# StorCLI2 ships with the HBAviewer plugin; /opt is RAM on Unraid, so it is
# restored to /opt/MegaRAID at boot from the flash copy.
fcp2_sas_tool() {
  local c
  for c in /opt/MegaRAID/storcli2/storcli2 /usr/local/sbin/storcli2 \
           /usr/sbin/storcli2 /opt/MegaRAID/storcli/storcli64 \
           /usr/local/sbin/storcli64 /usr/sbin/storcli64; do
    [[ -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  local p
  for p in storcli2 storcli64 storcli; do
    c=$(command -v "$p" 2>/dev/null) && [[ -n "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

# Writes lines of the form
#   c0.name=eHBA 9600-24i Tri-Mode Storage Adapter
#   c0.chip=58
#   c0.board=39
# StorCLI2 has no `show temperature` subcommand on any build, so the chip and
# board readings only appear under the full `show all`.
fcp2_sas_refresh() {
  local tool n c
  tool=$(fcp2_sas_tool) || return 1
  _fcp2_cache_fresh "$FCP2_SAS_CACHE" "$FCP2_SAS_TTL" && return 0

  mkdir -p "$FCP2_CACHE_DIR" 2>/dev/null
  local lock_fd
  exec {lock_fd}>"$FCP2_SAS_CACHE.lock" || return 1
  flock "$lock_fd"
  if ! _fcp2_cache_fresh "$FCP2_SAS_CACHE" "$FCP2_SAS_TTL"; then
    : >"$FCP2_SAS_CACHE.tmp"
    n=$("$tool" show ctrlcount 2>/dev/null |
          awk -F= '/Controller Count/ { gsub(/[^0-9]/,"",$2); print $2; exit }')
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    for (( c = 0; c < n; c++ )); do
      "$tool" /c$c show all 2>/dev/null | awk -v c="$c" '
        /^Product Name[[:space:]]*=/ {
          sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, "")
          if (length($0)) print "c" c ".name=" $0
        }
        /^Chip temperature\(C\)[[:space:]]*=/ {
          gsub(/[^0-9]/, "", $NF); if (length($NF)) print "c" c ".chip=" $NF
        }
        /^Board temperature\(C\)[[:space:]]*=/ {
          gsub(/[^0-9]/, "", $NF); if (length($NF)) print "c" c ".board=" $NF
        }
        # Older SAS2/SAS3 storcli builds report the ROC instead. Untested
        # here - this box is a 9600-series (mpi3mr / StorCLI2).
        /ROC temperature/ {
          gsub(/[^0-9]/, "", $NF); if (length($NF)) print "c" c ".chip=" $NF
        }
      ' >>"$FCP2_SAS_CACHE.tmp"
    done
    if [[ -s "$FCP2_SAS_CACHE.tmp" ]]; then
      mv -f "$FCP2_SAS_CACHE.tmp" "$FCP2_SAS_CACHE"
    else
      rm -f "$FCP2_SAS_CACHE.tmp"
    fi
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-

  [[ -s "$FCP2_SAS_CACHE" ]]
}

# fcp2_sas_temp <ctrl_index> <chip|board>
fcp2_sas_temp() {
  local c="$1" which="$2" v
  fcp2_sas_refresh || return 1
  v=$(awk -F= -v k="c${c}.${which}" '$1 == k { print $2; exit }' "$FCP2_SAS_CACHE")
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}
