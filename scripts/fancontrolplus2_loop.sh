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

# ===== Fan Speed on Idle / Unreadable (ABS) =====
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

# 刻意不再把 idle 夹到 Min 以下。
# 「读不到温度」有两种含义，方向相反：磁盘全部休眠（无害，应该更安静）；
# 已启用的传感器读不出来（失去可见性，应该保守地吹快一点）。
# 由用户按每个风扇自己决定，所以这里只夹到 [0, max]。

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

# ===== 轮询周期（秒）=====
# interval_sec 是权威值；老配置只有 interval（分钟），按分钟换算。
# 10 秒下限：再快也没有意义，smartctl 一轮就要几百毫秒。
period="${interval_sec:-$(( ${interval:-2} * 60 ))}"
[[ "$period" =~ ^[0-9]+$ ]] || period=60
(( period < 10 )) && period=10

# 缓存 TTL 必须短于本风扇的周期，否则会拿到自己上一轮留下的读数。
# 跟随周期自适应：10s 的风扇给 5s，5 分钟的风扇给 20s。
FCP2_IPMI_TTL=$(( period / 2 )); (( FCP2_IPMI_TTL < 3 )) && FCP2_IPMI_TTL=3; (( FCP2_IPMI_TTL > 20 )) && FCP2_IPMI_TTL=20
FCP2_SAS_TTL=$((  period / 2 )); (( FCP2_SAS_TTL  < 4 )) && FCP2_SAS_TTL=4;  (( FCP2_SAS_TTL  > 30 )) && FCP2_SAS_TTL=30

# ===== 抗震荡 =====
# hysteresis：温度相对「上次真正采纳的温度」变化不足这么多度，就沿用旧目标。
#   它只挡住「重新计算目标」，不挡住向目标滑行 —— 否则温度一稳定，风扇就会
#   永远卡在半路上到不了目标转速。
# slew_down / slew_up：每轮允许的 PWM 变化上限，0 = 不限。向上默认不限（安全
#   与响应速度优先），向下默认每轮 8，避免掉速时一大跳。
hysteresis="${hysteresis:-2}"
slew_down="${slew_down:-8}"
slew_up="${slew_up:-0}"
[[ "$hysteresis" =~ ^[0-9]+$ ]] || hysteresis=2
[[ "$slew_down"  =~ ^[0-9]+$ ]] || slew_down=8
[[ "$slew_up"    =~ ^[0-9]+$ ]] || slew_up=0

prev_pwm=-1        # 最后一次真正写进 sysfs 的值
intended_pwm=-1    # 限速后的意图值：小步会在这里累积，直到够格写出去
target_pwm=-1      # 经迟滞门控后的目标
acted_temp=-9999   # 上次采纳目标时的温度

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

  # ===== 迟滞：决定是否采纳新目标 =====
  # 温度相对「上次采纳时」变化够大才重算目标，否则沿用旧目标。
  # 关键：这只挡住「换目标」，不挡住下面继续向目标滑行。
  if [[ ! "$max_temp" =~ ^[0-9]+$ ]] || (( hysteresis <= 0 )) || (( acted_temp == -9999 )); then
    accept=1
  else
    dt=$(( max_temp - acted_temp )); (( dt < 0 )) && dt=$(( -dt ))
    if (( dt >= hysteresis )); then accept=1; else accept=0; fi
  fi
  if (( accept == 1 )); then
    target_pwm=$pwm_val
    [[ "$max_temp" =~ ^[0-9]+$ ]] && acted_temp=$max_temp
  fi
  (( target_pwm == -1 )) && target_pwm=$pwm_val

  # ===== 限速：向目标滑行 =====
  # intended_pwm 独立于「真正写出的值」累积，所以小于写入阈值的步进不会被丢弃，
  # 攒够了自然写得出去 —— 「降速卡在半路再也下不来」正是没做这件事导致的。
  if (( intended_pwm == -1 )); then
    intended_pwm=$target_pwm
  else
    d=$(( target_pwm - intended_pwm ))
    if (( d > 0 )); then
      if (( slew_up > 0 && d > slew_up )); then
        intended_pwm=$(( intended_pwm + slew_up ))
      else
        intended_pwm=$target_pwm
      fi
    elif (( d < 0 )); then
      if (( slew_down > 0 && -d > slew_down )); then
        intended_pwm=$(( intended_pwm - slew_down ))
      else
        intended_pwm=$target_pwm
      fi
    fi
  fi

  # ===== 写出 =====
  # 变化够大才写；但若已经滑到目标却还差最后一小步没写，也补写一次。
  do_write=0
  if (( prev_pwm == -1 )); then
    do_write=1
  else
    dp=$(( intended_pwm - prev_pwm )); (( dp < 0 )) && dp=$(( -dp ))
    if (( dp >= 5 )); then
      do_write=1
    elif (( dp > 0 && intended_pwm == target_pwm )); then
      do_write=1
    fi
  fi

  slept=0
  if (( do_write == 1 )); then
    first=$(( prev_pwm == -1 ? 1 : 0 ))
    [[ -f "$controller_enable" ]] && echo 1 > "$controller_enable"
    echo "$intended_pwm" > "$controller"
    sleep 4; slept=4
    if [[ -n "$fan_path" && -f "$fan_path" ]]; then
      rpm=$(cat "$fan_path")
    else
      rpm="?"
    fi
    label="[${custom}]"
    if (( first == 1 )) || [[ -z "$log_enable" || "$log_enable" == "1" ]]; then
      logger -t fancontrolplus2 "$label Temp=${max_temp}°C $temp_origin → PWM=$intended_pwm → RPM=$rpm"
    fi
    prev_pwm=$intended_pwm
  fi

  # 写出后已经睡了 4 秒，从周期里扣掉，免得周期被悄悄拉长
  rest=$(( period - slept )); (( rest < 1 )) && rest=1
  sleep "$rest"
done
