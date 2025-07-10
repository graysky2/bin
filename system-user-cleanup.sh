#!/bin/bash
BLD="\033[01m" RED="\033[01;31m" GRN="\033[01;32m" YLW="\033[01;33m" NRM="\033[00m"

if (command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi emoji) || 
  (printf "✅" 2>/dev/null | grep -q "✅" 2>/dev/null); then
EMPTY="✅"; FILES="📁"; LOCKED="🔒"; UNLOCKED="🔓"
else
  EMPTY="✓"; FILES="✗"; LOCKED="[L]"; UNLOCKED="[U]"
fi

is_empty() {
  [[ -d "$1" ]] || return 2
  shopt -s nullglob dotglob
  files=("$1"/*)
  shopt -u nullglob dotglob
  [[ ${#files[@]} -eq 0 ]]
  }

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

format_two_columns() {
  local -n col1=$1
  local -n col2=$2
  local col1_title="$3"
  local col2_title="$4"
  local max_col1_width=0
  local max_col2_width=0

  # Find max width for each column
  for item in "${col1[@]}"; do
    if [[ ${#item} -gt $max_col1_width ]]; then
      max_col1_width=${#item}
    fi
  done

  for item in "${col2[@]}"; do
    if [[ ${#item} -gt $max_col2_width ]]; then
      max_col2_width=${#item}
    fi
  done

  # Ensure minimum width for headers
  if [[ ${#col1_title} -gt $max_col1_width ]]; then
    max_col1_width=${#col1_title}
  fi
  if [[ ${#col2_title} -gt $max_col2_width ]]; then
    max_col2_width=${#col2_title}
  fi

  # Print headers
  printf "     %-${max_col1_width}s  %-${max_col2_width}s\n" "$col1_title" "$col2_title"
  printf "     "
  for ((i=0; i<max_col1_width; i++)); do printf "-"; done
  printf "  "
  for ((i=0; i<max_col2_width; i++)); do printf "-"; done
  printf "\n"

  # Print rows
  local max_rows=${#col1[@]}
    if [[ ${#col2[@]} -gt $max_rows ]]; then
      max_rows=${#col2[@]}
    fi

    for ((i=0; i<max_rows; i++)); do
      local item1="${col1[i]:-}"
      local item2="${col2[i]:-}"
      printf "     %-${max_col1_width}s  %-${max_col2_width}s\n" "$item1" "$item2"
    done
  }

is_account_expired() {
  local user="$1"
  local expire_date

  # Get the account expiration date from /etc/shadow
  expire_date=$(getent shadow "$user" 2>/dev/null | cut -d: -f8)

  # If no expiration date is set, account is not expired
  if [[ -z "$expire_date" || "$expire_date" == "" ]]; then
    return 1
  fi

  # Convert days since epoch to current date
  local current_days=$(( $(date +%s) / 86400 ))

  # If expire_date is less than current_days, account is expired
  if [[ "$expire_date" -lt "$current_days" ]]; then
    return 0
  else
    return 1
  fi
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

  # list of dirs under /var/lib/
  mapfile -t allinvarlib < <(find /var/lib -mindepth 1 -maxdepth 1 -type d | sed 's|/var/lib/||g' | sort | uniq)

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

  # difference between dirnames defined in /etc/passwd and what is on /var/lib/
  mapfile -t varlibquestion < <(comm -13 <(printf '%s\n' "${defined[@]}") <(printf '%s\n' "${allinvarlib[@]}"))
}

report() {
  echo -e "${BLD}>>> Users to be kept:${NRM}"
  format_array keep
  printf "\n\n"
  echo -e "${RED}>>> Users to be deleted:${NRM}"
  format_array delete
  printf "\n\n"
  if [[ -n "${defined[*]}" ]]; then
    echo -e "${GRN}>>> Users to be recreated based on what is present in sysuser.d files:${NRM}"
    format_array recreate
    printf "\n"
  fi
  if [[ -n "${orphaned[*]}" ]]; then
    printf "\n"
    echo -e "${YLW}>>> Users that have been orphaned by non-present packages:${NRM}"
    format_array orphaned
    printf "\n\n"

    has_homedirs=false
    for user in "${orphaned[@]}"; do
      homedir=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
      if [[ -n "$homedir" && "$homedir" != "/" ]] && [[ -d "$homedir" || $(is_empty "$homedir"; echo $?) -ne 2 ]]; then
        has_homedirs=true
        break
      fi
    done
    if [[ "$has_homedirs" == true ]]; then
      echo -e "${YLW}>>> Consider removing the following orphaned home directories:${NRM}"
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

report2() {
  if [[ -n "${varlibquestion[*]}" ]]; then
    printf "\n"
    echo -e "${YLW}>>> Dirs which may or may not be homedirs for manual review:${NRM}"
    for dirname in "${varlibquestion[@]}"; do
      [ -n "$dirname" ] && [ "$dirname" != "/" ] || continue
      if is_empty "$dirname"; then
        printf "     %s %s: %s (empty)\n" "$EMPTY" "$dirname"
      else
        printf "     %s %s: %s (has files)\n" "$FILES" "$dirname"
      fi
    done
  fi
}

lockedstatus() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}>>> $0 must run this as root for this function${NRM}"
    exit 1
  fi

  if [[ -n "${delete[*]}" ]]; then
    printf "\n"
    echo -e "${YLW}>>> User account locked/expired status:${NRM}"

    expired_users=()
    active_users=()

    for user in "${delete[@]}"; do
      if is_account_expired "$user"; then
        expired_users+=("$user")
      else
        active_users+=("$user")
      fi
    done

    format_two_columns expired_users active_users "$LOCKED Locked/Expired" "$UNLOCKED Unlocked/active"
    printf "\n"
  fi
}

doit() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}>>> $0 must run this as root for this function${NRM}"
    exit 1
  else
    for i in "${delete[@]}"; do
      userdel "$i"
    done
    systemd-sysusers
  fi
}

case "$1" in
  a|A|analyze|Analyze)
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
l|L|lockq|Lockq)
  findem && lockedstatus
  ;;
i|I|inspect|Inspect)
  findem && report2
  ;;
*)
  cat << EOF
Usage: $0 {analyze|delete|inspect}
 analyze : analyze users in /etc/passwd and in sysuser.d files and report
 delete  : delete and recreate users (requires root and will delete users!)
 lockq   : show defined user account and their locked status
 inspect : inspect structure of /var/lib/ and report
EOF
;;
esac
