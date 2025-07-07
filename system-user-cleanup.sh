#!/bin/bash
BLD="\033[01m"
RED="\033[01;31m"
GRN="\033[01;32m"
YLW="\033[01;33m"
NRM="\033[00m"

if (command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi emoji) || 
  (printf "✅" 2>/dev/null | grep -q "✅" 2>/dev/null); then
EMPTY="✅"; FILES="📁"
else
  EMPTY="✓"; FILES="✗"
fi

is_empty() {
  [[ -d "$1" ]] || return 2
  shopt -s nullglob dotglob
  files=("$1"/*)
  shopt -u nullglob dotglob
  [[ ${#files[@]} -eq 0 ]]
}

findem() {
  # all users defined
  mapfile -t passwd < <(awk -F: '{ print $1 }' /etc/passwd | sort)

  # keep all users with uid >= 1000 except for 65534 which is hard coded as nobody
  mapfile -t keep < <(awk -F: '$3 >= 1000 && $3 != 65534 { print $1 }' /etc/passwd)
  keep+=(root)

  # users to delete
  mapfile -t delete < <(
    for user in "${passwd[@]}"; do
      if [[ ! " ${keep[*]} " =~ " $user " ]]; then
        echo "$user"
      fi
    done
  )

  # users with sysuser files
  for i in /etc /run /usr/local/lib /usr/lib; do
    if [[ -d "$i"/sysusers.d ]]; then
      dirs+=("$i"/sysusers.d)
    fi
  done

  if [[ -n "${dirs[*]}" ]]; then
    mapfile -t defined < <(
      for dir in "${dirs[@]}"; do
        if [[ -d "$dir" ]]; then
          find "$dir" -name "*.conf" -type f -print0
        fi
      done | xargs -0 -r awk '/^u/{print $2}' | sort -u
    )
  fi

  # differences and orphaned users
  mapfile -t recreate < <(comm -12 <(printf '%s\n' "${defined[@]}") <(printf '%s\n' "${delete[@]}"))
  mapfile -t orphaned < <(comm -13 <(printf '%s\n' "${defined[@]}") <(printf '%s\n' "${delete[@]}"))
}

report() {
  # Format array output with line breaks for long lists
  format_array() {
    local -n arr=$1
    local line_length=5  # Start at 5 for initial indent
    local max_length=80
    local first_item=true
    printf "     "  # Initial 5-space indent
    for item in "${arr[@]}"; do
      if [[ "$first_item" == true ]]; then
        printf "%s" "$item"
        line_length=$((5 + ${#item}))
        first_item=false
      elif (( line_length + ${#item} + 1 > max_length )); then
        printf "\n     %s" "$item"
        line_length=$((5 + ${#item}))
      else
        printf " %s" "$item"
        line_length=$((line_length + ${#item} + 1))
      fi
    done
  }

  printf "${BLD}>>> Users to be kept:${NRM}\n"
  format_array keep
  printf "\n\n"
  printf "${RED}>>> Users to be deleted:${NRM}\n"
  format_array delete
  printf "\n\n"
  if [[ -n "${defined[*]}" ]]; then
    printf "${GRN}>>> Users to be recreated:${NRM}\n"
    format_array recreate
    printf "\n"
  fi
  if [[ -n "${orphaned[*]}" ]]; then
    printf "\n"
    printf "${YLW}>>> Users who have been orphaned by non-present packages:${NRM}\n"
    format_array orphaned
    printf "\n\n"
    # Check if any orphaned users have valid home directories before showing the header
    has_homedirs=false
    for user in "${orphaned[@]}"; do
      homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
      if [[ -n "$homedir" && "$homedir" != "/" ]] && [[ -d "$homedir" || $(is_empty "$homedir"; echo $?) -ne 2 ]]; then
        has_homedirs=true
        break
      fi
    done

    if [[ "$has_homedirs" == true ]]; then
      printf "${YLW}>>> Consider removing the following orphaned home directories:${NRM}\n"
      for user in "${orphaned[@]}"; do
        homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
        [ -n "$homedir" ] && [ "$homedir" != "/" ] || continue
        if is_empty "$homedir"; then
          printf "     %s %s: %s (empty)\n" "$EMPTY" "$user" "$homedir"
        elif [ -d "$homedir" ]; then
          printf "     %s %s: %s (has files)\n" "$FILES" "$user" "$homedir"
        fi
      done
    fi
  fi
}

doit() {
  if [[ $EUID -ne 0 ]]; then
    printf "${RED}>>> must run this as root${NRM}\n"
    exit 1
  else
    for i in "${delete[@]}"; do
      userdel "$i"
    done
    systemd-sysusers
  fi
}

case "$1" in
  s|S|show|Show)
    findem && report
    ;;
  d|D|delete|Delete)
    findem && doit
    cat <<EOF
>>> Manually inspect the ownership on dirs in /var/lib/ to insure parity with
    potentially changed UID/GID values. For example /var/lib/libuuid should be
    owned by uuidd:uuidd so chown -R uuidd:uuidd /var/lib/libuuid and so on.
EOF
    ;;
  *)
    cat << EOF
Usage: $0 {show|delete}
 show:   information output
 delete: delete and recreate users (requires root and will delete users!)
EOF
    ;;
esac
