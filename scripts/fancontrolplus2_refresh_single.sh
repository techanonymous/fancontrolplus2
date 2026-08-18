#!/bin/bash
# fancontrolplus2_refresh_single.sh
plugin="fancontrolplus2"
cfg_path="/boot/config/plugins/$plugin"
custom="$1"
cfg_file="$cfg_path/${plugin}_$custom.cfg"
[[ -f "$cfg_file" ]] || exit 1
source "$cfg_file"
max="${max:-255}"
controller_enable="${controller}_enable"

# IPMI / SAS 温度源（共享缓存，见 fcp2_sensor_sources.sh）
_fcp2_lib="$(dirname "$(readlink -f "$0")")/fcp2_sensor_sources.sh"
if [[ -f "$_fcp2_lib" ]]; then
  source "$_fcp2_lib"
else
  fcp2_ipmi_temp() { return 1; }
  fcp2_sas_temp()  { return 1; }
  fcp2_scale() { echo 0; }
fi

# === CPU 温度 ===
cpu_pwm_val=0
if [[ "${cpu_enable:-0}" == "1" && -n "$cpu_sensor" && -f "$cpu_sensor" ]]; then
  raw=$(cat "$cpu_sensor")
  [[ "$raw" =~ ^[0-9]+$ ]] && cpu_temp=$((raw / 1000))
  cpu_temp=${cpu_temp:-0}

  if (( cpu_temp <= cpu_min_temp )); then
    cpu_pwm_val=$pwm
  elif (( cpu_temp >= cpu_max_temp )); then
    cpu_pwm_val=$max
  else
    delta=$((cpu_temp - cpu_min_temp))
    range=$((cpu_max_temp - cpu_min_temp))
    (( range == 0 )) && range=1
    cpu_pwm_val=$((pwm + delta * (max - pwm) / range))
  fi
else
  cpu_temp="-"
fi

# === IPMI 温度 ===
ipmi_pwm_val=0
ipmi_temp="-"
if [[ "${ipmi_enable:-0}" == "1" && -n "${ipmi_sensor:-}" ]]; then
  if t=$(fcp2_ipmi_temp "$ipmi_sensor" "${ipmi_sensor_name:-}"); then
    ipmi_temp=$t
    ipmi_pwm_val=$(fcp2_scale "$t" "${ipmi_min_temp:-40}" "${ipmi_max_temp:-70}" "$pwm" "$max")
  fi
fi

# === SAS 控制器温度 ===
sas_pwm_val=0
sas_temp="-"
if [[ "${sas_enable:-0}" == "1" && -n "${sas_ctrl:-}" ]]; then
  if t=$(fcp2_sas_temp "$sas_ctrl" "${sas_probe:-chip}"); then
    sas_temp=$t
    sas_pwm_val=$(fcp2_scale "$t" "${sas_min_temp:-55}" "${sas_max_temp:-80}" "$pwm" "$max")
  fi
fi

# === Disk 温控 PWM ===
disk_pwm_val=0
disk_max="*"

# 有勾选 disk 时才处理
if [ -n "$disks" ]; then
  disk_max_valid=0
  found_valid_temp=0

  IFS=',' read -ra disks_list <<< "$disks"
  for disk in "${disks_list[@]}"; do
    disk_path="/dev/disk/by-id/$disk"
    real_path=$(realpath "$disk_path" 2>/dev/null)
    [[ ! -b "$real_path" ]] && continue

    # 跳过休眠磁盘
    smartctl -n standby -A "$real_path" | grep -q "Device is in STANDBY" && continue

    # 获取温度
    if [[ "$real_path" == /dev/nvme* ]]; then
      temp=$(smartctl -A "$real_path" | awk '/Temperature:/ {print $2; exit}')
    else
      temp=$(smartctl -A "$real_path" | awk '
        $1 == 190 || $1 == 194                   { print $10; exit }
        $1 == "Temperature_Celsius"             { print $10; exit }
        $1 == "Airflow_Temperature_Cel"         { print $10; exit }
        $1 == "Current" && $3 == "Temperature:" { print $4; exit }
      ')
    fi

    # 有效温度，更新最大值
    if [[ "$temp" =~ ^[0-9]+$ ]]; then
      (( temp > disk_max_valid )) && disk_max_valid=$temp
      found_valid_temp=1
    fi
  done

  # 若取得有效温度，再执行 PWM 推算
  if (( found_valid_temp == 1 )); then
    disk_max=$disk_max_valid

    if (( disk_max <= low )); then
      disk_pwm_val=$pwm
    elif (( disk_max >= high )); then
      disk_pwm_val=$max
    else
      delta=$((disk_max - low))
      range=$((high - low))
      (( range == 0 )) && range=1
      disk_pwm_val=$((pwm + delta * (max - pwm) / range))
    fi
  fi
fi
  
# === 取最高 PWM 作为最终值，同时设定 max_temp 与来源 ===
pwm_val=$disk_pwm_val
max_temp=$disk_max
temp_origin=$([ -n "$disks" ] && echo "(Disk)" || echo "")

for _src in "CPU:$cpu_pwm_val:$cpu_temp" \
            "IPMI:$ipmi_pwm_val:$ipmi_temp" \
            "SAS:$sas_pwm_val:$sas_temp"; do
  IFS=: read -r _name _spwm _stemp <<< "$_src"
  if (( _spwm > pwm_val )); then
    pwm_val=$_spwm
    max_temp=$_stemp
    temp_origin="($_name)"
  fi
done

# 避免空写入
if [[ ! "$max_temp" =~ ^[0-9]+$ ]]; then
  max_temp="*"
  temp_origin=""
fi

# 强制写 PWM
[[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
echo "$pwm_val" > "$controller"
sleep 4

# 采集 RPM
fan_index=""
if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
  fan_index="${BASH_REMATCH[1]}"
  fan_path="$(dirname "$controller")/fan${fan_index}_input"
fi
if [[ -n "$fan_path" && -f "$fan_path" ]]; then
  rpm=$(cat "$fan_path")
else
  rpm="?"
fi

label="[${custom}]"
logger -t fancontrolplus2 "Manual Run $label Temp=${max_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"

echo "${max_temp} ${temp_origin}" > "/var/tmp/fancontrolplus2/temp_${plugin}_${custom}"