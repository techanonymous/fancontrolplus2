#!/bin/bash
# fancontrolplus2_loop.sh - 实际运行的风扇控制脚本
# 温度源：Disk / CPU / IPMI / SAS controller，取各来源算出的最高 PWM。

cfg_file="$1"
[[ -f "$cfg_file" ]] || exit 1
source "$cfg_file"
max="${max:-255}"

# IPMI / SAS 温度源（共享缓存，见 fcp2_sensor_sources.sh）
# 若缺少该库则退化为「读不到」，其余温度源不受影响。
_fcp2_lib="$(dirname "$(readlink -f "$0")")/fcp2_sensor_sources.sh"
if [[ -f "$_fcp2_lib" ]]; then
  source "$_fcp2_lib"
else
  fcp2_ipmi_temp() { return 1; }
  fcp2_sas_temp()  { return 1; }
  fcp2_scale() { echo 0; }
fi

# ===== Fan Speed on Idle (ABS) =====
# 最小档（绝对值）：cfg 里的 pwm 就是 Min
min_pwm_abs="${pwm:-0}"

if [[ -n "${idle:-}" ]]; then
  idle_pwm_abs="$idle"
elif [[ -n "${idle_percent:-}" ]]; then
  idle_pwm_abs=$(( (idle_percent * 255 + 50) / 100 ))
else
  idle_pwm_abs=0
fi

# 基本夹值到 [0, max]
(( idle_pwm_abs < 0 )) && idle_pwm_abs=0
(( idle_pwm_abs > max )) && idle_pwm_abs="$max"

# Idle 不高于 Min
if (( idle_pwm_abs > min_pwm_abs )); then
  idle_pwm_abs="$min_pwm_abs"
fi

plugin="fancontrolplus2"
custom="${custom:-$(basename "$cfg_file" .cfg)}"
controller_enable="${controller}_enable"

# syslog 开关只在启动时读一次，避免每轮 grep 一次 cfg
log_enable=$(grep '^syslog=' "$cfg_file" | cut -d'"' -f2)
[[ -z "$log_enable" ]] && log_enable="1"

# 推导 RPM 读取路径
if [[ "$controller" =~ pwm([0-9]+)$ ]]; then
  fan_index="${BASH_REMATCH[1]}"
  fan_path="$(dirname "$controller")/fan${fan_index}_input"
else
  fan_path=""
fi

prev_pwm=-1

while true; do
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
  # Disk 为基准，其余温度源依次比较；同分时保留先到者（Disk 优先），
  # 与只有 Disk/CPU 两个来源时的行为一致。
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

  # 若无任何有效温度源 → 覆盖为 idle，并标注来源
  if [[ "$max_temp" == "*" ]]; then
    pwm_val="$idle_pwm_abs"
    temp_origin="(Idle)"
  fi

  # 每轮都写入 Dashboard 缓存
  echo "${max_temp} ${temp_origin}" > "/var/tmp/fancontrolplus2/temp_${plugin}_${custom}"

  # === 若 PWM 有明显变化，或首次 ===
  if [[ "$prev_pwm" == -1 ]]; then
    [[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
    echo "$pwm_val" > "$controller"
    sleep 4
    if [[ -n "$fan_path" && -f "$fan_path" ]]; then
      rpm=$(cat "$fan_path")
    else
      rpm="?"
    fi

    # 无条件写一次
    label="[${custom}]"
    logger -t fancontrolplus2 "$label Temp=${max_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"
    prev_pwm=$pwm_val
  else
    if (( pwm_val - prev_pwm >= 5 || prev_pwm - pwm_val >= 5 )); then
      [[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
      echo "$pwm_val" > "$controller"
      sleep 4
      if [[ -n "$fan_path" && -f "$fan_path" ]]; then
        rpm=$(cat "$fan_path")
      else
        rpm="?"
      fi

      label="[${custom}]"
      if [[ -z "$log_enable" || "$log_enable" == "1" ]]; then
        logger -t fancontrolplus2 "$label Temp=${max_temp}°C $temp_origin → PWM=$pwm_val → RPM=$rpm"
      fi

      prev_pwm=$pwm_val
    fi
  fi

  sleep $((interval * 60))
done