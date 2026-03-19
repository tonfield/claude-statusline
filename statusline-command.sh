#!/bin/bash
export LC_CTYPE=en_US.UTF-8
# Claude Code status line — car dashboard layout
# Line 1: think ●●●●○○○○○○ │ context [◇free][◆cache][▼in][▲out]
# Line 2: 5h ▁▂▃▄▅▆▇█ ×0.7  [green capacity][red wait]┃[grey elapsed]  ◑→85%
# Line 3: 7d ▁▂▃▄▅▆▇█ ×0.4  [green capacity][red wait]┃[grey elapsed]  ◔→45%
# Line 4: tokens [ses 23k│day 45k│all 120k] │ cost [ses $2│day $4│all $48]
# Line 5: ✦ Opus 4.6 │ ◉ dir │ ⎇ branch
input=$(cat)

# ── colors ────────────────────────────────────────────────────────────────────
RST="\033[0m"
BOLD="\033[1m"

C_MODEL="\033[38;2;255;165;60m"       # warm orange  — model name
C_DIR="\033[38;2;76;208;222m"         # cyan         — directory
C_BRANCH="\033[38;2;192;103;222m"     # purple       — git branch
C_LBL="\033[1;97m"                    # bright white — labels / markers
C_DIM="\033[38;2;140;146;160m"        # muted grey   — inactive elements
C_SEP="\033[38;2;80;86;100m"          # dark grey    — separators
C_GRN="\033[38;2;80;220;120m"         # green        — low usage
C_YLW="\033[38;2;230;190;60m"         # yellow       — mid usage
C_RED="\033[38;2;240;90;90m"          # red          — high usage
C_BAR="\033[38;2;220;220;220m"        # light grey   — text inside bars

BG_GRN="\033[48;2;50;150;75m"         # green bar bg
BG_YLW="\033[48;2;190;165;25m"        # yellow bar bg
BG_RED="\033[48;2;150;50;50m"         # red bar bg (matches input red)
BG_EMPTY="\033[48;2;35;38;48m"        # dark slate — empty/inactive bg
BG_GHOST="\033[48;2;65;68;82m"        # mid slate  — elapsed time bg
BG_USED1="\033[48;2;200;70;70m"       # bright red — cache segment
BG_USED2="\033[48;2;150;50;50m"       # medium red — input segment
BG_USED3="\033[48;2;100;35;35m"       # dim red    — output segment
BG_GOLD1="\033[48;2;200;155;30m"      # bright gold — session cost
BG_GOLD2="\033[48;2;130;105;25m"      # medium gold — today cost
BG_GOLD3="\033[48;2;75;62;20m"        # dim gold   — all cost
BG_BLUE1="\033[48;2;55;105;200m"      # bright blue — session tokens
BG_BLUE2="\033[48;2;38;72;140m"       # medium blue — today tokens
BG_BLUE3="\033[48;2;25;48;90m"        # dim blue   — all tokens

T_YLW="\033[38;2;80;70;10m"           # dark yellow — text on yellow bg

CACHE="/tmp/.claude_usage_cache"
COST_LOG="$HOME/.claude/usage_costs.tsv"

# ── helpers ───────────────────────────────────────────────────────────────────
bar() {
  local w1=$1 w2=$2 bg1=${3:-$BG_GRN} bg2=${4:-$BG_EMPTY}
  [ "$w1" -gt 0 ] 2>/dev/null && printf "%b%${w1}s%b" "$bg1" "" "$RST"
  [ "$w2" -gt 0 ] 2>/dev/null && printf "%b%${w2}s%b" "$bg2" "" "$RST"
}

seg() {
  local w=$1 bg=$2 fg=$3 txt=$4
  [ "$w" -le 0 ] 2>/dev/null && return
  if [ -n "$txt" ] && [ $(( ${#txt} + 2 )) -le "$w" ]; then
    local lp=$(( (w - ${#txt}) / 2 )); local rp=$(( w - ${#txt} - lp ))
    printf "%b%b%${lp}s%s%${rp}s%b" "$bg" "$fg" "" "$txt" "" "$RST"
  else
    printf "%b%${w}s%b" "$bg" "" "$RST"
  fi
}

secs_until() {
  local clean=$(echo "$1" | sed 's/\.[0-9]*//;s/[+-][0-9][0-9]:[0-9][0-9]$//;s/Z$//')
  local reset=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null) || return
  local diff=$(( reset - $(date -u +%s) ))
  [ "$diff" -le 0 ] && echo "0" && return
  echo "$diff"
}

_fmt_secs() {
  local s=$1
  [ -z "$s" ] || [ "$s" -le 0 ] 2>/dev/null && printf "0m" && return
  local d=$(( s/86400 )) h=$(( s%86400/3600 )) m=$(( s%3600/60 ))
  if [ "$d" -gt 0 ]; then printf "%dd%dh" "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf "%dh%dm" "$h" "$m"
  else printf "%dm" "$m"
  fi
}

_timeline_str() {
  local fuel_s=$1 dry_s=$2 remain_s=$3 window_s=$4 limit_pct=$5 time_pct=$6 fuel_bg=${7:-$BG_GRN}
  local _TLW=44

  local filled=$(( limit_pct * _TLW / 100 ))
  [ "$filled" -gt "$_TLW" ] && filled=$_TLW
  [ "$filled" -lt 0 ] && filled=0

  local marker=$(( time_pct * _TLW / 100 ))
  [ "$marker" -ge "$_TLW" ] && marker=$(( _TLW - 1 ))
  [ "$marker" -lt 0 ] && marker=0

  local fuel_label="${limit_pct}%"
  local fl=${#fuel_label}
  local fl_start=0 fl_end=0
  if [ "$filled" -ge $(( fl + 2 )) ]; then
    fl_start=$(( (filled - fl) / 2 ))
    fl_end=$(( fl_start + fl ))
  else
    fl=0
  fi

  local dry_label="" dl=0 dl_start=0 dl_end=0
  local wait_w=0
  if [ "$filled" -lt "$marker" ]; then
    wait_w=$(( marker - filled ))
    if [ "$dry_s" -gt 0 ] 2>/dev/null; then
      local _dry_full="◷$(_fmt_secs "$dry_s")"
      local _dry_short _dry_overflow=""
      local _ds=$dry_s
      local _dd=$(( _ds/86400 )) _dh=$(( _ds%86400/3600 )) _dm=$(( _ds%3600/60 ))
      if [ "$_dd" -gt 0 ]; then _dry_short="◷${_dd}d+"
      elif [ "$_dh" -gt 0 ]; then _dry_short="◷${_dh}h+"
      else _dry_short="◷${_dm}m"
      fi
      if [ "$wait_w" -ge $(( ${#_dry_full} + 2 )) ]; then
        dry_label="$_dry_full"
      elif [ "$wait_w" -ge $(( ${#_dry_short} + 2 )) ]; then
        dry_label="$_dry_short"
      else
        _dry_overflow="$_dry_short"
      fi
      dl=${#dry_label}
      if [ "$dl" -gt 0 ]; then
        dl_start=$(( filled + (wait_w - dl) / 2 ))
        dl_end=$(( dl_start + dl ))
      fi
    fi
  fi

  local _ghost_label="" _gl=0
  if [ -n "$_dry_overflow" ]; then
    _ghost_label="←$_dry_overflow"
    _gl=${#_ghost_label}
  fi

  local i=0
  while [ $i -lt "$_TLW" ]; do
    if [ $i -eq "$marker" ]; then
      printf "%b┃%b" "$C_LBL" "$RST"
    elif [ $i -lt "$filled" ]; then
      if [ "$fl" -gt 0 ] && [ $i -ge "$fl_start" ] && [ $i -lt "$fl_end" ]; then
        printf "%b%b%s%b" "$fuel_bg" "$C_BAR" "${fuel_label:$(( i - fl_start )):1}" "$RST"
      else
        printf "%b %b" "$fuel_bg" "$RST"
      fi
    elif [ $i -lt "$marker" ]; then
      if [ "$dl" -gt 0 ] && [ $i -ge "$dl_start" ] && [ $i -lt "$dl_end" ]; then
        printf "%b%b%s%b" "$BG_USED3" "$C_BAR" "${dry_label:$(( i - dl_start )):1}" "$RST"
      else
        printf "%b %b" "$BG_USED3" "$RST"
      fi
    else
      local _gi=$(( i - marker - 1 ))
      if [ "$_gl" -gt 0 ] && [ "$_gi" -ge 0 ] && [ "$_gi" -lt "$_gl" ]; then
        printf "%b%b%s%b" "$BG_GHOST" "$C_RED" "${_ghost_label:$_gi:1}" "$RST"
      else
        printf "%b %b" "$BG_GHOST" "$RST"
      fi
    fi
    i=$(( i + 1 ))
  done
}

fmt_tok() {
  local t=${1%.*}
  [ -z "$t" ] || [ "$t" = "null" ] && printf "–" && return
  if [ "$t" -ge 1000000 ] 2>/dev/null; then
    printf "%d.%dm" "$(( t / 1000000 ))" "$(( t % 1000000 / 100000 ))"
  elif [ "$t" -ge 1000 ] 2>/dev/null; then
    printf "%dk" "$(( t / 1000 ))"
  else
    printf "%d" "$t"
  fi
}

sep() { printf " %b│%b " "$C_SEP" "$RST"; }

BAR_COL=9
_lbl() {
  printf "%b%s%b" "$C_LBL" "$1" "$RST"
  local pad=$(( BAR_COL - ${#1} ))
  [ "$pad" -gt 0 ] && printf "%${pad}s" ""
}

# Character-fill bar: uses a repeated char instead of solid bg
# Args: width filled char color value_text
_char_bar() {
  local w=$1 filled=$2 ch=$3 color=$4 val=$5
  [ "$filled" -gt "$w" ] && filled=$w
  [ "$filled" -lt 0 ] && filled=0
  local vl=${#val}
  local bar_start=0
  [ "$vl" -gt 0 ] && bar_start=$(( vl + 1 ))
  local i=0
  while [ $i -lt "$w" ]; do
    if [ "$vl" -gt 0 ] && [ $i -lt "$vl" ]; then
      printf "%b%b%s%b" "$BOLD" "$color" "${val:$i:1}" "$RST"
    elif [ "$vl" -gt 0 ] && [ $i -eq "$vl" ]; then
      printf " "
    elif [ $(( i - bar_start )) -lt "$filled" ]; then
      printf "%b%s%b" "$color" "$ch" "$RST"
    else
      printf "%b·%b" "$C_DIM" "$RST"
    fi
    i=$(( i + 1 ))
  done
}

stacked_bar() {
  local sv=$1 dv=$2 av=$3 sl=$4 dl=$5 al=$6 bg1=$7 bg2=$8 bg3=$9
  local BW=44
  [ -z "$av" ] || [ "$av" -le 0 ] 2>/dev/null && return
  local dr=$(( dv - sv )); [ "$dr" -lt 0 ] && dr=0
  local ar=$(( av - dv )); [ "$ar" -lt 0 ] && ar=0
  local smin=0 dmin=0 amin=0
  [ "$sv" -gt 0 ] 2>/dev/null && smin=$(( ${#sl} + 2 ))
  [ "$dr" -gt 0 ] 2>/dev/null && dmin=$(( ${#dl} + 2 ))
  [ "$ar" -gt 0 ] 2>/dev/null && amin=$(( ${#al} + 2 ))
  local sw=$(( sv * BW / av ))
  local dw=$(( dr * BW / av ))
  [ "$sv" -gt 0 ] 2>/dev/null && [ "$sw" -lt "$smin" ] && sw=$smin
  [ "$dr" -gt 0 ] 2>/dev/null && [ "$dw" -lt "$dmin" ] && dw=$dmin
  local aw=$(( BW - sw - dw ))
  if [ "$ar" -gt 0 ] 2>/dev/null && [ "$aw" -lt "$amin" ]; then
    aw=$amin; BW=$(( sw + dw + aw ))
  fi
  [ "$aw" -lt 0 ] && aw=0
  local fg1=${10:-$C_BAR}
  seg "$sw" "$bg1" "$fg1" "$sl"
  [ "$dw" -gt 0 ] && seg "$dw" "$bg2" "$C_BAR" "$dl"
  [ "$aw" -gt 0 ] && seg "$aw" "$bg3" "$C_BAR" "$al"
}


# ── data (single jq call) ───────────────────────────────────────────────────
_jq_out=$(echo "$input" | jq -r '[
  (.model.display_name // ""),
  (.workspace.current_dir // .cwd // ""),
  (.context_window.used_percentage // ""),
  (if .context_window.current_usage != null then
    ((.context_window.current_usage.cache_read_input_tokens // 0)
    + (.context_window.current_usage.cache_creation_input_tokens // 0)
    + (.context_window.current_usage.input_tokens // 0)
    + (.context_window.current_usage.output_tokens // 0))
  else "" end),
  (.context_window.context_window_size // ""),
  (.cost.total_cost_usd // ""),
  (.cost.total_duration_ms // ""),
  (.cost.total_api_duration_ms // ""),
  (.context_window.total_input_tokens // ""),
  (.context_window.total_output_tokens // ""),
  (.context_window.current_usage.cache_read_input_tokens // 0),
  (.context_window.current_usage.cache_creation_input_tokens // 0),
  (.context_window.current_usage.input_tokens // 0),
  (.context_window.current_usage.output_tokens // 0),
  (.session_id // "")
] | @tsv')
IFS=$'\t' read -r model dir used tokens ctxsize cost dur_ms api_ms total_in total_out cache_read cache_create cur_input cur_output session_id <<< "$_jq_out"

dir_short=$(basename "$dir")
branch=$(git --git-dir="$dir/.git" symbolic-ref --short HEAD 2>/dev/null)
if [ -n "$branch" ]; then
  _git_status=$(git -C "$dir" status --porcelain 2>/dev/null)
  _git_staged=$(echo "$_git_status" | grep -c '^[MADRC]' 2>/dev/null)
  _git_modified=$(echo "$_git_status" | grep -c '^.[MADRC?]' 2>/dev/null)
  [ -z "$_git_status" ] && _git_clean=1 || _git_clean=0
fi

dur_int=${dur_ms%.*}
api_int=${api_ms%.*}
io_in=$(( cache_read + cache_create + cur_input ))
io_out=$cur_output

# ── rate limit data (single file read + batched awk) ────────────────────────
five_h_proj=""
seven_d_proj=""
mult_5h=""
mult_7d=""
has_limits=0
if [ -f "$CACHE" ]; then
  has_limits=1
  { read -r five_h; read -r seven_d; read -r five_r; read -r seven_r; } < "$CACHE"
  s5=$(secs_until "$five_r")
  if [ -n "$s5" ] && [ "$s5" -gt 0 ] 2>/dev/null; then
    elapsed5=$(( 18000 - s5 ))
    if [ "$elapsed5" -gt 0 ] 2>/dev/null; then
      read -r five_h_proj mult_5h <<< "$(awk "BEGIN {
        printf \"%.0f %.1f\", $five_h * 18000 / $elapsed5, $five_h * 18000 / ($elapsed5 * 100)
      }")"
    fi
  fi
  s7=$(secs_until "$seven_r")
  if [ -n "$s7" ] && [ "$s7" -gt 0 ] 2>/dev/null; then
    elapsed7=$(( 604800 - s7 ))
    if [ "$elapsed7" -gt 0 ] 2>/dev/null; then
      read -r seven_d_proj mult_7d <<< "$(awk "BEGIN {
        printf \"%.0f %.1f\", $seven_d * 604800 / $elapsed7, $seven_d * 604800 / ($elapsed7 * 100)
      }")"
    fi
  fi
fi

# ── cost + tokens (single awk pass over log) ────────────────────────────────
day_cost="" all_cost="" rate="" rate_c="" day_tok="" all_tok=""
sess_in=${total_in:-0}; sess_out=${total_out:-0}
[ "$sess_in" = "null" ] && sess_in=0
[ "$sess_out" = "null" ] && sess_out=0
sess_tok=$(( sess_in + sess_out ))
if [ -n "$cost" ] && [ "$cost" != "null" ] && [ -n "$session_id" ]; then
  today=$(date +%Y-%m-%d)
  mkdir -p "$(dirname "$COST_LOG")"
  touch "$COST_LOG"
  if grep -q "^$session_id	" "$COST_LOG" 2>/dev/null; then
    sed -i '' "s/^$session_id	.*/$session_id	$today	$cost	$sess_in	$sess_out/" "$COST_LOG"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$session_id" "$today" "$cost" "$sess_in" "$sess_out" >> "$COST_LOG"
  fi
  read -r all_cost day_cost all_tok day_tok <<< "$(awk -F'\t' -v d="$today" '{
    ac += $3; at += $4 + $5
    if ($2 == d) { dc += $3; dt += $4 + $5 }
  } END { printf "%.0f %.0f %.0f %.0f", ac, dc, at, dt }' "$COST_LOG")"
fi
if [ -n "$cost" ] && [ "$cost" != "null" ] && [ -n "$dur_int" ] && [ "$dur_int" -gt 0 ] 2>/dev/null; then
  read -r rate rate_c <<< "$(awk "BEGIN {
    printf \"%.2f %.0f\", $cost / ($dur_int / 3600000.0), $cost * 100 / ($dur_int / 3600000.0)
  }")"
fi

# ── api throughput ──────────────────────────────────────────────────────────
api_tph=""
if [ -n "$api_int" ] && [ "$api_int" -gt 5000 ] 2>/dev/null; then
  if [ -n "$total_in" ] && [ "$total_in" != "null" ] && [ "$total_in" -gt 1000 ] 2>/dev/null && \
     [ -n "$total_out" ] && [ "$total_out" != "null" ] && [ "$total_out" -gt 0 ] 2>/dev/null; then
    api_tph_sum=$(( total_in + total_out ))
  else
    api_tph_sum=$(( io_in + io_out ))
  fi
  [ "$api_tph_sum" -gt 0 ] 2>/dev/null && \
    api_tph=$(awk "BEGIN { printf \"%.0f\", $api_tph_sum / ($api_int / 3600000.0) }")
fi

has_api=0; api_pct=0
if [ -n "$dur_int" ] && [ "$dur_int" -gt 0 ] && [ -n "$api_int" ] && [ "$api_int" -gt 0 ] 2>/dev/null; then
  has_api=1
  api_pct=$(( api_int * 100 / dur_int ))
  [ "$api_pct" -gt 100 ] && api_pct=100
fi

# ── emit ─────────────────────────────────────────────────────────────────────
ctx_int=""
[ -n "$used" ] && ctx_int=$(printf '%.0f' "$used")

# Rate limit countdown values
remain_5h=0; remain_7d=0; time_5h=0; time_7d=0
if [ "$has_limits" -eq 1 ]; then
  remain_5h=$(( 100 - five_h ))
  remain_7d=$(( 100 - seven_d ))
  [ -n "$s5" ] && [ "$s5" -gt 0 ] 2>/dev/null && time_5h=$(( s5 * 100 / 18000 ))
  [ -n "$s7" ] && [ "$s7" -gt 0 ] 2>/dev/null && time_7d=$(( s7 * 100 / 604800 ))
  [ "$time_5h" -gt 100 ] && time_5h=100
  [ "$time_7d" -gt 100 ] && time_7d=100
fi

# Multiplier-based colors: green < 0.8, yellow 0.8–1.2, red >= 1.2
bc_5h="$C_YLW"; bg_5h="$BG_YLW"
bc_7d="$C_YLW"; bg_7d="$BG_YLW"
if [ -n "$mult_5h" ]; then
  _m5c=$(awk "BEGIN { m=$mult_5h+0; if (m<0.9) print \"g\"; else if (m>=1.1) print \"r\"; else print \"y\" }")
  if   [ "$_m5c" = "g" ]; then bc_5h="$C_GRN"; bg_5h="$BG_GRN"
  elif [ "$_m5c" = "r" ]; then bc_5h="$C_RED"; bg_5h="$BG_RED"
  fi
fi
if [ -n "$mult_7d" ]; then
  _m7c=$(awk "BEGIN { m=$mult_7d+0; if (m<0.9) print \"g\"; else if (m>=1.1) print \"r\"; else print \"y\" }")
  if   [ "$_m7c" = "g" ]; then bc_7d="$C_GRN"; bg_7d="$BG_GRN"
  elif [ "$_m7c" = "r" ]; then bc_7d="$C_RED"; bg_7d="$BG_RED"
  fi
fi

# Timelines
timer_5h=""
timer_7d=""
if [ "$has_limits" -eq 1 ]; then
  if [ -n "$five_h_proj" ] && [ "$five_h_proj" -ge 100 ] 2>/dev/null && \
     [ -n "$s5" ] && [ "$s5" -gt 0 ] 2>/dev/null && \
     [ -n "$elapsed5" ] && [ "$elapsed5" -gt 0 ] 2>/dev/null; then
    _fuel5=$(awk "BEGIN { v = (100 - $five_h) * $elapsed5 / $five_h; printf \"%.0f\", (v > 0) ? v : 0 }")
    [ "$_fuel5" -gt "$s5" ] 2>/dev/null && _fuel5=$s5
    timer_5h=$(_timeline_str "$_fuel5" "$(( s5 - _fuel5 ))" "$s5" 18000 "$remain_5h" "$time_5h" "$bg_5h")
  elif [ -n "$s5" ] && [ "$s5" -gt 0 ] 2>/dev/null; then
    timer_5h=$(_timeline_str "$s5" 0 "$s5" 18000 "$remain_5h" "$time_5h" "$bg_5h")
  fi
  if [ -n "$seven_d_proj" ] && [ "$seven_d_proj" -ge 100 ] 2>/dev/null && \
     [ -n "$s7" ] && [ "$s7" -gt 0 ] 2>/dev/null && \
     [ -n "$elapsed7" ] && [ "$elapsed7" -gt 0 ] 2>/dev/null; then
    _fuel7=$(awk "BEGIN { v = (100 - $seven_d) * $elapsed7 / $seven_d; printf \"%.0f\", (v > 0) ? v : 0 }")
    [ "$_fuel7" -gt "$s7" ] 2>/dev/null && _fuel7=$s7
    timer_7d=$(_timeline_str "$_fuel7" "$(( s7 - _fuel7 ))" "$s7" 604800 "$remain_7d" "$time_7d" "$bg_7d")
  elif [ -n "$s7" ] && [ "$s7" -gt 0 ] 2>/dev/null; then
    timer_7d=$(_timeline_str "$s7" 0 "$s7" 604800 "$remain_7d" "$time_7d" "$bg_7d")
  fi
fi

# ── line 1: speed + cost rate bars ───────────────────────────────────
io_fresh=$(( cache_create + cur_input ))
BG_FREE="\033[48;2;50;150;75m"
if [ "$has_api" -eq 1 ]; then
  _lbl "rate"
  # Speed half (21 chars): ▶ fill, scaled 0-1M t/h
  _sf=0; _sc="$C_GRN"
  if [ -n "$api_tph" ] && [ "$api_tph" -gt 0 ] 2>/dev/null; then
    _sf=$(( api_tph * 21 / 1000000 ))
    [ "$_sf" -lt 1 ] && _sf=1
    [ "$_sf" -gt 21 ] && _sf=21
    if   [ "$api_tph" -ge 1000000 ] 2>/dev/null; then _sc="$C_RED"
    elif [ "$api_tph" -ge 500000 ]  2>/dev/null; then _sc="$C_YLW"
    fi
  fi
  _sv="$(fmt_tok "$api_tph")/h"
  printf "%b[%b" "$C_DIM" "$RST"
  _char_bar 21 "$_sf" "▶" "$_sc" "$_sv"
  printf "%b][%b" "$C_DIM" "$RST"
  # Cost half (20 chars): $ fill, ~$1 per char, yellow $5+, red $10+
  _cf=0; _cc="$C_GRN"
  if [ -n "$rate_c" ] && [ "$rate_c" -gt 0 ] 2>/dev/null; then
    _cf=$(( rate_c * 21 / 2100 ))
    [ "$_cf" -lt 1 ] && _cf=1
    [ "$_cf" -gt 21 ] && _cf=21
    if   [ "$rate_c" -ge 1000 ] 2>/dev/null; then _cc="$C_RED"
    elif [ "$rate_c" -ge 500 ]  2>/dev/null; then _cc="$C_YLW"
    fi
  fi
  _cv="\$${rate}/h"
  _char_bar 21 "$_cf" "\$" "$_cc" "$_cv"
  printf "%b]%b\n" "$C_DIM" "$RST"
fi
# Think bar aligned with bars below (44 chars at BAR_COL)
_lbl "think"
THINK_W=44
printf "%b[%b" "$C_DIM" "$RST"
if [ "$has_api" -eq 1 ]; then
  _tc="$C_GRN"
  if   [ "$api_pct" -ge 80 ] 2>/dev/null; then _tc="$C_RED"
  elif [ "$api_pct" -ge 50 ] 2>/dev/null; then _tc="$C_YLW"
  fi
  _tf=$(( api_pct * THINK_W / 100 ))
  [ "$_tf" -gt "$THINK_W" ] && _tf=$THINK_W
  _ti=1
  while [ $_ti -le "$THINK_W" ]; do
    if [ $_ti -le "$_tf" ]; then printf "%b●%b" "$_tc" "$RST"
    else printf "%b·%b" "$C_DIM" "$RST"
    fi
    _ti=$(( _ti + 1 ))
  done
else
  _ti=1; while [ $_ti -le "$THINK_W" ]; do printf "%b·%b" "$C_DIM" "$RST"; _ti=$(( _ti + 1 )); done
fi
printf "%b]%b\n" "$C_DIM" "$RST"

# ── line 2: context ─────────────────────────────────────────────────
CTX_BASE=44
if [ -n "$ctxsize" ] && [ "$ctxsize" -gt 0 ] && [ -n "$tokens" ] 2>/dev/null; then
  _tokens_left=$(( ctxsize - tokens ))
  [ "$_tokens_left" -lt 0 ] && _tokens_left=0
  _lc="◆$(fmt_tok "$cache_read")"; _lf="▼$(fmt_tok "$io_fresh")"; _lo="▲$(fmt_tok "$io_out")"
  _lfree="◇$(fmt_tok "$_tokens_left")"
  _cmin=0; _fmin=0; _omin=0; _frmin=0
  [ "$cache_read" -gt 0 ] 2>/dev/null && _cmin=$(( ${#_lc} + 2 ))
  [ "$io_fresh" -gt 0 ] 2>/dev/null && _fmin=$(( ${#_lf} + 2 ))
  [ "$io_out" -gt 0 ] 2>/dev/null && _omin=$(( ${#_lo} + 2 ))
  [ "$_tokens_left" -gt 0 ] 2>/dev/null && _frmin=$(( ${#_lfree} + 2 ))
  CTX_W=$CTX_BASE
  _used_w=$(( tokens * CTX_W / ctxsize ))
  [ "$tokens" -gt 0 ] 2>/dev/null && [ "$_used_w" -eq 0 ] && _used_w=1
  _free_w=$(( CTX_W - _used_w ))
  [ "$_free_w" -lt "$_frmin" ] && _free_w=$_frmin
  if [ "$tokens" -gt 0 ] 2>/dev/null; then
    _fw=$(( io_fresh * _used_w / tokens ))
    _ow=$(( io_out * _used_w / tokens ))
    [ "$io_fresh" -gt 0 ] 2>/dev/null && [ "$_fw" -lt "$_fmin" ] && _fw=$_fmin
    [ "$io_out" -gt 0 ] 2>/dev/null && [ "$_ow" -lt "$_omin" ] && _ow=$_omin
    _cw=$(( _used_w - _fw - _ow ))
    [ "$cache_read" -gt 0 ] 2>/dev/null && [ "$_cw" -lt "$_cmin" ] && _cw=$_cmin
    [ "$_cw" -lt 0 ] && _cw=0
  else
    _cw=0; _fw=0; _ow=0
  fi
  # Clamp total to CTX_BASE — shrink free first, then cache
  _total=$(( _free_w + _cw + _fw + _ow ))
  if [ "$_total" -gt "$CTX_BASE" ]; then
    _free_w=$(( _free_w - (_total - CTX_BASE) ))
    [ "$_free_w" -lt 0 ] && { _cw=$(( _cw + _free_w )); _free_w=0; }
    [ "$_cw" -lt 0 ] && _cw=0
  fi
  _lbl "context"
  printf "%b[%b" "$C_DIM" "$RST"
  _bg_free="$BG_FREE"
  if   [ "$ctx_int" -ge 80 ] 2>/dev/null; then _bg_free="$BG_RED"
  elif [ "$ctx_int" -ge 65 ] 2>/dev/null; then _bg_free="$BG_YLW"
  fi
  seg "$_free_w" "$_bg_free" "$C_BAR" "$_lfree"
  seg "$_cw" "$BG_USED1" "$C_BAR" "$_lc"
  seg "$_fw" "$BG_USED2" "$C_BAR" "$_lf"
  seg "$_ow" "$BG_USED3" "$C_BAR" "$_lo"
  printf "%b]%b" "$C_DIM" "$RST"
else
  _lbl "context"
  printf "%b[%b" "$C_DIM" "$RST"
  bar 0 "$CTX_BASE" "" "$BG_FREE"
  printf "%b]%b %b–%b" "$C_DIM" "$RST" "$C_DIM" "$RST"
fi
printf "\n"

# ── lines 3-4: rate limits ──────────────────────────────────────────
_gauge() {
  local mult=$1
  [ -z "$mult" ] && printf "%b··┃··%b" "$C_DIM" "$RST" && return
  local pos
  pos=$(awk "BEGIN {
    m = $mult + 0
    if      (m < 0.45) p = 0
    else if (m < 0.9)  p = 1
    else if (m < 1.1)  p = 2
    else if (m < 1.55) p = 3
    else                p = 4
    printf \"%d\", p
  }")
  local i=0
  while [ $i -lt 5 ]; do
    if [ $i -eq "$pos" ]; then
      if   [ $i -lt 2 ]; then printf "%b%b●%b" "$BOLD" "$C_GRN" "$RST"
      elif [ $i -eq 2 ]; then printf "%b%b●%b" "$BOLD" "$C_YLW" "$RST"
      else                     printf "%b%b●%b" "$BOLD" "$C_RED" "$RST"
      fi
    elif [ $i -eq 2 ]; then printf "%b┃%b" "$C_DIM" "$RST"
    elif [ $i -lt 2 ]; then printf "%b·%b" "$C_GRN" "$RST"
    else                     printf "%b·%b" "$C_RED" "$RST"
    fi
    i=$(( i + 1 ))
  done
}

SBOX=7
_rate_line() {
  local lbl=$1 mult=$2 bc=$3 timer=$4
  printf "%b%s%b " "$C_LBL" "$lbl" "$RST"
  _gauge "$mult"
  printf " "
  printf "%b[%b" "$C_DIM" "$RST"
  if [ -n "$timer" ]; then
    printf "%s" "$timer"
  else
    seg 44 "$BG_GRN" "$C_BAR" ""
  fi
  printf "%b]%b\n" "$C_DIM" "$RST"
}

if [ "$has_limits" -eq 1 ]; then
  _rate_line "5h" "$mult_5h" "$bc_5h" "$timer_5h"
  _rate_line "7d" "$mult_7d" "$bc_7d" "$timer_7d"
else
  bash ~/.claude/fetch-usage.sh >/dev/null 2>&1 &
  printf "%bloading...%b\n" "$C_LBL" "$RST"
fi

# ── line 5: tokens ──────────────────────────────────────────────────
_day_t=${day_tok:-0}; _all_t=${all_tok:-0}
if [ "$_all_t" -gt 0 ] 2>/dev/null; then
  _tl_s="ses $(fmt_tok "$sess_tok")"; _tl_d="day $(fmt_tok "$_day_t")"; _tl_a="all $(fmt_tok "$_all_t")"
  _lbl "tokens"
  printf "%b[%b" "$C_DIM" "$RST"
  stacked_bar "$sess_tok" "$_day_t" "$_all_t" "$_tl_s" "$_tl_d" "$_tl_a" "$BG_BLUE1" "$BG_BLUE2" "$BG_BLUE3"
  printf "%b]%b" "$C_DIM" "$RST"
  printf "\n"
fi

# ── line 6: cost ────────────────────────────────────────────────────
_sess_c=0; _day_c=0; _all_c=0
[ -n "$cost" ] && [ "$cost" != "null" ] && _sess_c=$(awk "BEGIN { printf \"%.0f\", $cost * 100 }")
[ -n "$day_cost" ] && _day_c=$(( day_cost * 100 ))
[ -n "$all_cost" ] && _all_c=$(( all_cost * 100 ))
if [ "$_all_c" -gt 0 ] 2>/dev/null; then
  _cl_s="ses \$$(printf '%.0f' "$cost")"; _cl_d="day \$$day_cost"; _cl_a="all \$$all_cost"
  _lbl "cost"
  printf "%b[%b" "$C_DIM" "$RST"
  stacked_bar "$_sess_c" "$_day_c" "$_all_c" "$_cl_s" "$_cl_d" "$_cl_a" "$BG_GOLD1" "$BG_GOLD2" "$BG_GOLD3" "$T_YLW"
  printf "%b]%b" "$C_DIM" "$RST"
  printf "\n"
fi

# ── line 7: identity ────────────────────────────────────────────────
printf "%b✦%b %b%b%s%b" "$C_MODEL" "$RST" "$C_MODEL" "$BOLD" "$model" "$RST"
printf " %b│%b %b◉%b %b%s%b" "$C_SEP" "$RST" "$C_DIR" "$RST" "$C_DIR" "$dir_short" "$RST"
if [ -n "$branch" ]; then
  printf " %b│%b %b⎇%b %b%b%s%b" "$C_SEP" "$RST" "$C_BRANCH" "$RST" "$C_BRANCH" "$BOLD" "$branch" "$RST"
  if [ "$_git_clean" -eq 1 ] 2>/dev/null; then
    printf " %b✓%b" "$C_GRN" "$RST"
  else
    [ "$_git_staged" -gt 0 ] 2>/dev/null && printf " %b+%d%b" "$C_GRN" "$_git_staged" "$RST"
    [ "$_git_modified" -gt 0 ] 2>/dev/null && printf " %b~%d%b" "$C_YLW" "$_git_modified" "$RST"
  fi
fi
exit 0
