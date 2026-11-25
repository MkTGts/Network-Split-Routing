#!/usr/bin/env bash
set -euo pipefail
script_path="$(readlink -f -- "$0")"
script_dir="$(dirname -- "$script_path")"
dispatcher=/etc/NetworkManager/dispatcher.d/90-ktalk-wifi-route
config_dir=/etc/network-split-routing
config="$config_dir/resources.conf"

if (( EUID != 0 )); then
  if command -v pkexec >/dev/null 2>&1; then
    exec pkexec "$script_path" "$@"
  fi
  printf '%s\n' 'Запусти установщик с sudo: sudo ./install.sh' >&2
  exit 1
fi

for cmd in ip getent install; do
  command -v "$cmd" >/dev/null 2>&1 || { printf 'Не найдена команда: %s\n' "$cmd" >&2; exit 1; }
done
command -v nmcli >/dev/null 2>&1 || printf '%s\n' 'Предупреждение: nmcli не найден; IPv6-шлюз будет определяться по таблице маршрутов.' >&2
if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet NetworkManager; then
  printf '%s\n' 'NetworkManager не запущен. Установи/запусти NetworkManager и повтори установку.' >&2
  exit 1
fi

# Save the invoking user's HAPP state once, before any system changes.
caller_uid="${SUDO_UID:-${PKEXEC_UID:-$(id -u)}}"
passwd_entry=$(getent passwd "$caller_uid" || true)
if [[ -n "$passwd_entry" ]]; then
  caller_user=$(cut -d: -f1 <<< "$passwd_entry")
  caller_gid=$(cut -d: -f4 <<< "$passwd_entry")
  caller_home=$(cut -d: -f6 <<< "$passwd_entry")
else
  caller_user=root; caller_gid=0; caller_home=/root
fi
backup_dir="$caller_home/.local/state/network-split-routing/happ-before-install"
if [[ ! -e "$backup_dir/manifest" ]]; then
  install -d -o "$caller_uid" -g "$caller_gid" -m 700 "$backup_dir"
  routing_status=absent
  database_status=absent
  if [[ -f "$caller_home/.config/Happ/routing.json" ]]; then
    cp -p "$caller_home/.config/Happ/routing.json" "$backup_dir/routing.json"
    chmod 600 "$backup_dir/routing.json"
    routing_status=present
  fi
  if [[ -f "$caller_home/.config/Happ/subs.db" ]]; then
    cp -p "$caller_home/.config/Happ/subs.db" "$backup_dir/subs.db"
    chmod 600 "$backup_dir/subs.db"
    database_status=present
  fi
  printf 'routing_json=%s\nsubs_db=%s\nremove_generated_routes=0\n' \
    "$routing_status" "$database_status" > "$backup_dir/manifest"
  chown "$caller_uid:$caller_gid" "$backup_dir/manifest" "$backup_dir"/* 2>/dev/null || true
  chmod 600 "$backup_dir/manifest"
fi

install -D -m 755 "$script_dir/dispatcher.sh" "$dispatcher"
install -d -m 755 "$config_dir"
if [[ ! -e "$config" ]]; then
  install -m 644 "$script_dir/resources.conf" "$config"
else
  printf 'Сохраняю существующий список ресурсов: %s\n' "$config"
fi
"$dispatcher" __manual__ up
printf '%s\n' 'Установлено. NetworkManager будет обновлять исключения при изменении сети.'
printf 'Список ресурсов: %s\n' "$config"
