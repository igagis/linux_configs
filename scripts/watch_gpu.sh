#!/bin/bash
# watch_gpu.sh — live per-GPU sensor table (temps, VRAM, fan, clocks, power).
# Bash-only: data from `sensors` (text output) + /sys. Loops every 0.5 s; Ctrl-C quits.
set -euo pipefail
export LC_ALL=C

command -v sensors >/dev/null 2>&1 || { echo "watch_gpu: 'sensors' not found (install lm-sensors)" >&2; exit 1; }

Y=$'\033[33m'; G=$'\033[32m'; R=$'\033[31m'; WBG=$'\033[97;41m'; RES=$'\033[0m'

# PCI slot -> card number map (DRM sysfs)
declare -A CARD_BY_SLOT=()
for uev in /sys/class/drm/card[0-9]*/device/uevent; do
  if [ ! -r "$uev" ]; then continue; fi
  slot=""
  while IFS= read -r l; do
    if [[ $l == PCI_SLOT_NAME=* ]]; then slot=${l#PCI_SLOT_NAME=}; break; fi
  done < "$uev"
  if [ -n "$slot" ]; then
    slot=${slot#0000:}
    d=${uev%/device/uevent}
    CARD_BY_SLOT[$slot]=${d##*/card}
  fi
done

# --- helpers (result in REPLY) ---
tenths() { # "+63.0" | "63" -> 630
  local s=${1#+} i d
  i=${s%%.*}
  if [[ $s == *.* ]]; then d=${s#*.}; else d=""; fi
  d=${d:0:1}; if [ -z "$d" ]; then d=0; fi
  REPLY=$(( 10#$i * 10 + 10#$d ))
}
ghz() { # "96 MHz" | "0 Hz" | "2.32 GHz" -> REPLY "0.10" | "0.00" | "2.32"
  local s=$1 v u f6=1
  if [[ $s =~ ^([0-9]+(\.[0-9]+)?) ]]; then v=${BASH_REMATCH[1]}; else REPLY="-"; return 0; fi
  u=${s##* }
  case $u in
    GHz) f6=1000000000 ;;
    MHz) f6=1000000 ;;
    kHz) f6=1000 ;;
  esac
  local i=${v%%.*} d
  if [[ $v == *.* ]]; then d=${v#*.}; else d=""; fi
  d="${d}000000"; d=${d:0:6}
  local v6=$(( 10#$i * 1000000 + 10#$d ))
  local centi=$(( (v6 * f6 + 5000000000000) / 10000000000000 ))
  REPLY="$(printf '%d.%02d' "$((centi / 100))" "$((centi % 100))")"
}
watt() { # "289.600" -> "290" (round half up)
  local v=$1 i d
  if [[ $v == *.* ]]; then i=${v%%.*}; d=${v#*.}; else i=$v; d=""; fi
  d=${d:0:1}; if [ -z "$d" ]; then d=0; fi
  REPLY=$(( 10#$i + (10#$d >= 5) ))
}

# --- per-frame state ---
declare -a ADAPTERS=() KEYS=() CURS=() LABS=() IDXES=()
declare -A T=() CR=() EM=() FAN=() PWM=() SCLK=() MCLK=() PW=() CAP=()

read_sensors() {
  ADAPTERS=(); KEYS=(); CURS=(); LABS=(); IDXES=()
  T=(); CR=(); EM=(); FAN=(); PWM=(); SCLK=(); MCLK=(); PW=(); CAP=()
  local cur="" sec="" in_gpu=0 line t name rest
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line != [[:space:]]* ]]; then t=$line
    else t=${line#"${line%%[![:space:]]*}"}; fi   # strip leading spaces
    if [[ $t == \(* ]]; then                      # continuation: (emerg = ...) / (cap = ...)
      if [ "$in_gpu" -ne 1 ]; then continue; fi
      if [[ $t =~ emerg[[:space:]]*=[[:space:]]*\+?([0-9]+(\.[0-9]+)?) ]]; then EM["$cur|$sec"]=${BASH_REMATCH[1]}; fi
      if [[ $t =~ cap[[:space:]]*=[[:space:]]*\+?([0-9]+(\.[0-9]+)?) ]]; then CAP[$cur]=${BASH_REMATCH[1]}; fi
      continue
    fi
    if [[ $t != *:* ]]; then                      # adapter header (no colon)
      cur=$t
      in_gpu=0
      if [[ $cur == amdgpu-* ]]; then in_gpu=1; ADAPTERS+=("$cur"); fi
      sec=""
      continue
    fi
    if [ "$in_gpu" -ne 1 ]; then continue; fi
    name=${t%%:*}
    rest=${t#*:}
    sec=$name
    case $name in
      edge|junction|mem)
        if [[ $rest =~ ([+-]?[0-9]+(\.[0-9]+)?) ]]; then
          T["$cur|$name"]=${BASH_REMATCH[1]}
          if [[ $rest =~ crit[[:space:]]*=[[:space:]]*\+?([0-9]+(\.[0-9]+)?) ]]; then CR["$cur|$name"]=${BASH_REMATCH[1]}; fi
        fi ;;
      fan1)  if [[ $rest =~ ([0-9]+) ]]; then FAN[$cur]=${BASH_REMATCH[1]}; fi ;;
      pwm1)  if [[ $rest =~ ([0-9]+) ]]; then PWM[$cur]=${BASH_REMATCH[1]}; fi ;;
      sclk)  if [[ $rest =~ ([0-9]+(\.[0-9]+)?)[[:space:]]*([a-zA-Z]*) ]]; then SCLK[$cur]="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"; fi ;;
      mclk)  if [[ $rest =~ ([0-9]+(\.[0-9]+)?)[[:space:]]*([a-zA-Z]*) ]]; then MCLK[$cur]="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"; fi ;;
      PPT)
        if [[ $rest =~ ([0-9]+(\.[0-9]+)?) ]]; then PW[$cur]=${BASH_REMATCH[1]}; fi
        if [[ $rest =~ avg[[:space:]]+([0-9]+(\.[0-9]+)?) ]]; then PW[$cur]=${BASH_REMATCH[1]}; fi
        if [[ $rest =~ cap[[:space:]]*=[[:space:]]*\+?([0-9]+(\.[0-9]+)?) ]]; then CAP[$cur]=${BASH_REMATCH[1]}; fi
        ;;
    esac
  done

  # map adapters to card numbers, sort by card number
  local n=${#ADAPTERS[@]} i j cur hex slot idx m tmp
  for (( i=0; i<n; i++ )); do
    cur=${ADAPTERS[i]}
    hex=${cur##*-}
    slot="${hex:0:2}:${hex:2:2}.0"
    idx=${CARD_BY_SLOT[$slot]-}
    CURS+=("$cur")
    if [ -n "$idx" ]; then KEYS+=("$idx"); LABS+=("$idx"); IDXES+=("$idx")
    else KEYS+=(9999); LABS+=("$slot"); IDXES+=(""); fi
  done
  for (( i=0; i<n; i++ )); do
    m=$i
    for (( j=i+1; j<n; j++ )); do
      if (( KEYS[j] < KEYS[m] )); then m=$j; fi
    done
    if (( m != i )); then
      tmp=${KEYS[i]}; KEYS[i]=${KEYS[m]}; KEYS[m]=$tmp
      tmp=${CURS[i]}; CURS[i]=${CURS[m]}; CURS[m]=$tmp
      tmp=${LABS[i]}; LABS[i]=${LABS[m]}; LABS[m]=$tmp
      tmp=${IDXES[i]}; IDXES[i]=${IDXES[m]}; IDXES[m]=$tmp
    fi
  done
}

vram_cell() { # $1 = card number ("" = unmapped) -> REPLY_C / REPLY_P
  local c="-" p="-"
  if [ -n "$1" ]; then
    local uf=/sys/class/drm/card$1/device/mem_info_vram_used
          tf=/sys/class/drm/card$1/device/mem_info_vram_total
    if [ -r "$uf" ] && [ -r "$tf" ]; then
      local ub tb u100 t100 f100
      ub=$(<"$uf"); tb=$(<"$tf")
      u100=$(( (ub * 100 + 5368709) / 1073741824 ))
      t100=$(( (tb * 100 + 5368709) / 1073741824 ))
      f100=$(( t100 - u100 ))
      c="${Y}$((u100 / 100)).$(printf '%02d' "$((u100 % 100))")${RES}/$((t100 / 100)).$(printf '%02d' "$((t100 % 100))")/${G}$((f100 / 100)).$(printf '%02d' "$((f100 % 100))")${G}"
      p="$(printf '%d.%02d/%d.%02d/%d.%02d' "$((u100 / 100))" "$((u100 % 100))" "$((t100 / 100))" "$((t100 % 100))" "$((f100 / 100))" "$((f100 % 100))")"
    fi
  fi
  REPLY_C=$c; REPLY_P=$p
}

temp_cell() { # $1 = adapter -> REPLY_C / REPLY_P
  local cur=$1 out="" plain="" sec v tv ev cv disp col
  for sec in edge junction mem; do
    v=${T["$cur|$sec"]-}
    if [ -n "$v" ]; then
      tenths "$v"; tv=$REPLY
      disp=$(( (tv + 5) / 10 ))
      col=""
      ev=${EM["$cur|$sec"]-}
      if [ -n "$ev" ]; then
        tenths "$ev"
        if (( tv >= REPLY )); then col=$WBG; fi
      fi
      if [ -z "$col" ]; then
        cv=${CR["$cur|$sec"]-}
        if [ -n "$cv" ]; then
          tenths "$cv"
          if (( tv >= REPLY )); then col=$R
          elif (( tv >= REPLY - 100 )); then col=$Y; fi
        fi
      fi
      out+="${col}${disp}${RES}"
      plain+="$disp"
    else
      out+="-"; plain+="-"
    fi
    out+="/"; plain+="/"
  done
  REPLY_C=${out%/}; REPLY_P=${plain%/}
}

# flat cell arrays: A=colored, AP=plain, AL=display length; layout: hdr1(6) hdr2(6) rows(6*n)
A=(); AP=(); AL=()
W=()

dlen() { # display length (bytes minus UTF-8 continuation bytes; LC_ALL=C is byte-based)
  local s=$1 n=0 i c
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [$'\200'-$'\277']) : ;;
      *) n=$(( n + 1 )) ;;
    esac
  done
  REPLY=$n
}

cell() { # $1=width $2=plain display len $3=colored -> REPLY = centered, 1-space padded
  local pad=$(( $1 - $2 )) left=$(( ($1 - $2) / 2 )) right sp
  right=$(( pad - left ))
  REPLY=" "
  if (( left > 0 )); then printf -v sp '%*s' "$left" ""; REPLY+="$sp"; fi
  REPLY+="$3"
  if (( right > 0 )); then printf -v sp '%*s' "$right" ""; REPLY+="$sp"; fi
  REPLY+=" "
}

print_row() { # $1 = flat offset
  local off=$1 out="│" i idx
  for (( i=0; i<6; i++ )); do
    idx=$(( off + i ))
    cell "${W[i]}" "${AL[idx]}" "${A[idx]}"
    out+="${REPLY}│"
  done
  printf '%s\033[K\n' "$out"
}

print_sep() {
  local out="├" i k line
  for (( i=0; i<6; i++ )); do
    line=""
    for (( k=0; k<=W[i]+1; k++ )); do line+="─"; done
    out+="$line"
    if (( i < 5 )); then out+="┼"; else out+="┤"; fi
  done
  printf '%s\033[K\n' "$out"
}

render() {
  A=(); AP=(); W=()
  local h1=("card" "vram" "edge/junc/mem" "fan/pwm" "sclk/mclk" "power/cap")
  local h2=("" "(GiB)" "(°C)" "(rpm/%)" "(GHz)" "(W)")
  local n=${#CURS[@]} i j cur
  local -a C1P=() C1C=() C2P=() C2C=() C3=() C4=() C5=()

  A+=("${h1[@]}"); AP+=("${h1[@]}")
  A+=("${h2[@]}"); AP+=("${h2[@]}")

  for (( i=0; i<n; i++ )); do
    cur=${CURS[i]}
    vram_cell "${IDXES[i]}"; C1P+=("${REPLY_P}"); C1C+=("${REPLY_C}")
    temp_cell "$cur"; C2P+=("${REPLY_P}"); C2C+=("${REPLY_C}")
    local fp=${FAN[$cur]-} pw=${PWM[$cur]-}
    if [ -z "$fp" ]; then fp="-"; fi
    if [ -n "$pw" ]; then pw="${pw}%"; else pw="-"; fi
    C3+=("$fp/$pw")
    local sc=${SCLK[$cur]-} mc=${MCLK[$cur]-}
    if [ -n "$sc" ]; then ghz "$sc"; sc=$REPLY; else sc="-"; fi
    if [ -n "$mc" ]; then ghz "$mc"; mc=$REPLY; else mc="-"; fi
    C4+=("$sc/$mc")
    local pv=${PW[$cur]-} cv=${CAP[$cur]-}
    if [ -n "$pv" ]; then watt "$pv"; pv=$REPLY; else pv="-"; fi
    if [ -n "$cv" ]; then watt "$cv"; cv=$REPLY; else cv="-"; fi
    C5+=("$pv/$cv")
    A+=("${LABS[i]}" "${C1C[i]}" "${C2C[i]}" "${C3[i]}" "${C4[i]}" "${C5[i]}")
    AP+=("${LABS[i]}" "${C1P[i]}" "${C2P[i]}" "${C3[i]}" "${C4[i]}" "${C5[i]}")
  done

  local m k total=$(( 12 + n * 6 ))
  for (( i=0; i<6; i++ )); do
    dlen "${A[i]}"; m=$REPLY
    dlen "${A[i+6]}"; if (( REPLY > m )); then m=$REPLY; fi
    for (( j=0; j<n; j++ )); do
      dlen "${AP[12 + j * 6 + i]}"
      if (( REPLY > m )); then m=$REPLY; fi
    done
    W+=("$m")
  done
  for (( k=0; k<total; k++ )); do
    dlen "${AP[k]}"; AL[k]=$REPLY
  done

  print_row 0
  print_row 6
  print_sep
  for (( j=0; j<n; j++ )); do print_row $(( 12 + j * 6 )); done
}

printf '\033[2J'                      # clear once; afterwards overwrite in place (no flicker)
while true; do
  printf '\033[H'
  out=$(sensors) || { echo "watch_gpu: failed to read sensors" >&2; exit 1; }
  read_sensors <<< "$out"
  render
  sleep 0.5
done
