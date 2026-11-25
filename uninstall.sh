#!/usr/bin/env bash
set -euo pipefail
script_path="$(readlink -f -- "$0")"
if (( EUID != 0 )); then
  if command -v pkexec >/dev/null 2>&1; then exec pkexec "$script_path" "$@"; fi
  printf '%s\n' 'Запусти удаление с sudo: sudo ./uninstall.sh' >&2
  exit 1
fi

caller_uid="${SUDO_UID:-${PKEXEC_UID:-$(id -u)}}"
passwd_entry=$(getent passwd "$caller_uid" || true)
if [[ -n "$passwd_entry" ]]; then
  caller_user=$(cut -d: -f1 <<< "$passwd_entry")
  caller_gid=$(cut -d: -f4 <<< "$passwd_entry")
  caller_home=$(cut -d: -f6 <<< "$passwd_entry")
else
  caller_user=root; caller_gid=0; caller_home=/root
fi

state=/run/ktalk-wifi-routes
if [[ -f "$state" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == *" "* ]]; then iface="${line%% *}"; route="${line#* }"; else iface=wlp2s0; route="$line"; fi
    if [[ "$route" == *:* ]]; then ip -6 route del "$route" dev "$iface" 2>/dev/null || true; else ip -4 route del "$route" dev "$iface" 2>/dev/null || true; fi
  done < "$state"
  rm -f "$state"
fi
rm -f /etc/NetworkManager/dispatcher.d/90-ktalk-wifi-route

# Restore HAPP files captured by install.sh. The backup remains private for recovery.
backup_dir="$caller_home/.local/state/network-split-routing/happ-before-install"
restart_happ=0
if [[ -r "$backup_dir/manifest" ]]; then
  routing_json=absent
  subs_db=absent
  remove_generated_routes=0
  while IFS='=' read -r key value; do
    case "$key" in
      routing_json) routing_json="$value" ;;
      subs_db) subs_db="$value" ;;
      remove_generated_routes) remove_generated_routes="$value" ;;
    esac
  done < "$backup_dir/manifest"
  install -d -o "$caller_uid" -g "$caller_gid" -m 700 "$caller_home/.config/Happ"
  if [[ "$routing_json" == present && -f "$backup_dir/routing.json" ]]; then
    install -o "$caller_uid" -g "$caller_gid" -m 600 "$backup_dir/routing.json" "$caller_home/.config/Happ/routing.json"
    restart_happ=1
  fi
  if [[ "$subs_db" == present && -f "$backup_dir/subs.db" ]]; then
    install -o "$caller_uid" -g "$caller_gid" -m 600 "$backup_dir/subs.db" "$caller_home/.config/Happ/subs.db"
    restart_happ=1
  fi
  if [[ "$remove_generated_routes" == 1 ]]; then
    rm -rf \
      "$caller_home/.local/share/Happ/routing/0/ktalk-direct-rest-via-happ" \
      "$caller_home/.local/share/Happ/routing/0/ktalk-direct-rest-via-happ.update" \
      "$caller_home/.local/share/Happ/routing/629398284/ktalk-direct-rest-via-happ-629398284" \
      "$caller_home/.local/share/Happ/routing/629398284/ktalk-direct-rest-via-happ-629398284.update" \
      "$caller_home/.local/share/Happ/routing/-1079988869/ktalk-direct-rest-via-happ--1079988869" \
      "$caller_home/.local/share/Happ/routing/-1079988869/ktalk-direct-rest-via-happ--1079988869.update"
    restart_happ=1
  fi
  # Keep the private snapshot, but allow the next install to take a fresh one.
  rm -f "$backup_dir/manifest"
fi

printf '%s\n' 'Удалён NetworkManager-обработчик и созданные им маршруты.'
if (( restart_happ )); then
  printf '%s\n' 'Настройки HAPP восстановлены из снимка установки; перезапусти HAPP, чтобы он перечитал их.'
else
  printf '%s\n' 'HAPP-файлы до установки отсутствовали или не менялись; пользовательские настройки сохранены.'
fi
printf 'Список ресурсов оставлен для повторной установки: %s\n' /etc/network-split-routing/resources.conf
printf 'Резервная копия HAPP: %s\n' "$backup_dir"
