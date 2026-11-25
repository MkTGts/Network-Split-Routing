#!/usr/bin/env bash
set -u
requested_iface="${1:-}"
action="${2:-}"
config=/etc/network-split-routing/resources.conf
state=/run/ktalk-wifi-routes

log() {
  logger -t network-split-routing -- "$*" 2>/dev/null || true
}

remove_one() {
  local iface="$1" route="$2"
  [[ -n "$route" ]] || return 0
  if [[ "$route" == *:* ]]; then
    ip -6 route del "$route" dev "$iface" 2>/dev/null || true
  else
    ip -4 route del "$route" dev "$iface" 2>/dev/null || true
  fi
}

remove_all_saved() {
  [[ -f "$state" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *" "* ]]; then
      remove_one "${line%% *}" "${line#* }"
    else
      # Compatibility with state written by the older wlp2s0-only version.
      remove_one wlp2s0 "$line"
    fi
  done < "$state"
  rm -f "$state"
}

remove_iface_saved() {
  local target="$1" line saved_iface route temp
  [[ -f "$state" ]] || return 0
  temp=$(mktemp /run/ktalk-wifi-routes.XXXXXX)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *" "* ]]; then
      saved_iface="${line%% *}"; route="${line#* }"
    else
      saved_iface=wlp2s0; route="$line"
    fi
    if [[ "$saved_iface" == "$target" ]]; then
      remove_one "$saved_iface" "$route"
    else
      printf '%s %s\n' "$saved_iface" "$route" >> "$temp"
    fi
  done < "$state"
  if [[ -s "$temp" ]]; then mv -f "$temp" "$state"; else rm -f "$temp" "$state"; fi
}

select_default_iface() {
  local line dev metric best_iface="" best_metric=2147483647
  while IFS= read -r line; do
    dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<< "$line")
    [[ -n "$dev" && "$dev" != happ-xray && "$dev" != lo ]] || continue
    metric=$(awk '{for(i=1;i<=NF;i++) if($i=="metric") {print $(i+1); exit}}' <<< "$line")
    [[ "$metric" =~ ^[0-9]+$ ]] || metric=0
    if (( metric < best_metric )); then
      best_metric=$metric
      best_iface=$dev
    fi
  done < <(ip -4 route show default)
  printf '%s' "$best_iface"
}

if [[ "$action" == down || "$action" == pre-down ]]; then
  remove_iface_saved "$requested_iface"
  log "removed routes for disconnected interface $requested_iface"
  exit 0
fi
[[ "$action" == up || "$action" == dhcp4-change || "$action" == connectivity-change ]] || exit 0
[[ -r "$config" ]] || { log "missing config: $config"; exit 0; }
iface=$(select_default_iface)
[[ -n "$iface" ]] || { log 'no non-HAPP default route found'; exit 0; }

route_line=$(ip -4 route show default dev "$iface" | head -n1)
gw4=$(awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}' <<< "$route_line")
gw6=""
if command -v nmcli >/dev/null 2>&1; then
  gw6=$(nmcli -g IP6.GATEWAY device show "$iface" 2>/dev/null | awk '/:/ {print; exit}')
fi
if [[ -z "$gw6" ]]; then
  gw6=$(ip -6 route show dev "$iface" | awk '/ via / {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
fi

remove_all_saved
: > "$state"
add4() {
  local route="$1"
  if [[ -n "$gw4" ]]; then
    ip -4 route replace "$route" via "$gw4" dev "$iface" metric 20 2>/dev/null || return 0
  else
    ip -4 route replace "$route" dev "$iface" metric 20 2>/dev/null || return 0
  fi
  printf '%s %s\n' "$iface" "$route" >> "$state"
}
add6() {
  local route="$1"
  [[ -n "$gw6" ]] || return 0
  ip -6 route replace "$route" via "$gw6" dev "$iface" metric 20 2>/dev/null || return 0
  printf '%s %s\n' "$iface" "$route" >> "$state"
}

while read -r kind value _; do
  [[ -z "${kind:-}" || "$kind" == \#* ]] && continue
  case "$kind" in
    route4) add4 "$value" ;;
    route6) add6 "$value" ;;
    host)
      while IFS= read -r ip; do [[ -n "$ip" ]] && add4 "$ip/32"; done \
        < <(getent ahostsv4 "$value" | awk '{print $1}' | sort -u)
      if [[ -n "$gw6" ]]; then
        while IFS= read -r ip; do
          [[ -n "$ip" && "$ip" != ::ffff:* ]] && add6 "$ip/128"
        done < <(getent ahostsv6 "$value" | awk '{print $1}' | sort -u)
      fi
      ;;
    *) log "ignored unknown resource type: $kind" ;;
  esac
done < "$config"
log "applied direct routes using interface $iface gateway ${gw4:-none}"
