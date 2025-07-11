#!/bin/bash

BLD="\033[01m" RED="\033[01;31m" YLW="\033[01;33m" NRM="\033[00m"

if [[ $EUID -ne 0 ]]; then
  echo -e "${BLD} >>> ${RED}ERROR: ${NRM}${BLD}$0 must run as root${NRM}"
  exit 1
fi

if (command -v fc-list >/dev/null 2>&1 && fc-list | grep -qi emoji) || 
  (printf "✅" 2>/dev/null | grep -q "✅" 2>/dev/null); then
  CHECKMARK="✅"; LOCKED="🔒"; UNLOCKED="🔓"; NO="❌"; YO="⚠️ "
else
  CHECKMARK="[✓]"; LOCKED="[L]"; UNLOCKED="[U]" NO="[✗]" ; YO="[!]"
  true
fi

is_empty() {
  shopt -s nullglob dotglob
  files=("$1"/*)
  shopt -u nullglob dotglob
  [[ ${#files[@]} -eq 0 ]]
}

format_array() {
  local -n arr=$1
  local max_length=80
  local line_length=5
  printf "     "
  for item in "${arr[@]}"; do
    if (( line_length + ${#item} + 1 > max_length )); then
      printf "\n     %s" "$item"
      line_length=$((5 + ${#item}))
      else
        printf "%s " "$item"
        line_length=$((line_length + ${#item} + 1))
    fi
  done
  printf "\n"
}

format_two_columns() {
  local -n col1=$1
  local -n col2=$2
  local col1_title="$3"
  local col2_title="$4"
  local max_col1_width=0
  local max_col2_width=0

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

  if [[ ${#col1_title} -gt $max_col1_width ]]; then
    max_col1_width=${#col1_title}
  fi
  if [[ ${#col2_title} -gt $max_col2_width ]]; then
    max_col2_width=${#col2_title}
  fi

  printf "     %-${max_col1_width}s  %-${max_col2_width}s\n" "$col1_title" "$col2_title"
  printf "     %*s  %*s\n" "$max_col1_width" "" "$max_col2_width" "" | tr ' ' '-'

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

is_account_locked() {
  local user="$1"
  if chage -l "$user" | grep 'Account expires' | grep -q never; then
    return 1
  else
    return 0
  fi
}

parse_sysuser_files() {
  declare -gA sysuser_directives
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r -d '' file; do
        while IFS= read -r line; do
          [[ "$line" =~ ^[[:space:]]*# ]] && continue
          [[ "$line" =~ ^[[:space:]]*$ ]] && continue
          if [[ "$line" =~ ^[[:space:]]*(u!|u)[[:space:]]+([^[:space:]]+) ]]; then
            local directive="${BASH_REMATCH[1]}"
            local username="${BASH_REMATCH[2]}"
            sysuser_directives["$username"]="$directive"
          fi
        done < "$file"
      done < <(find "$dir" -name "*.conf" -type f -print0)
    fi
  done
}

findem() {
  mapfile -t passwd_user < <(awk -F: '{ print $1 }' /etc/passwd | sort)
  mapfile -t keep < <(awk -F: '$3 >= 1000 && $3 != 65534 { print $1 }' /etc/passwd)
  keep+=(root)

  mapfile -t delete < <(
    for user in "${passwd_user[@]}"; do
      if [[ ! " ${keep[*]} " =~ " $user " ]]; then
        echo "$user"
      fi
    done
  )

  for i in /etc /run /usr/local/lib /usr/lib; do
    if [[ -d "$i"/sysusers.d ]]; then
      dirs+=("$i"/sysusers.d)
    fi
  done

  mapfile -t defined < <(
    for dir in "${dirs[@]}"; do
      if [[ -d "$dir" ]]; then
        find "$dir" -name "*.conf" -type f -print0
      fi
    done | xargs -0 -r awk '/^u/{print $2}' | sort -u
  )

  parse_sysuser_files

  mapfile -t orphaned < <(comm -13 <(printf '%s\n' "${defined[@]}") <(printf '%s\n' "${delete[@]}"))

  if [[ ${#sysuser_directives[@]} -gt 0 ]]; then
    for user in "${!sysuser_directives[@]}"; do
      local directive="${sysuser_directives[$user]}"
      if ! getent passwd "$user" >/dev/null 2>&1; then
        continue
      fi
      if [[ "$directive" == "u!" ]]; then
        if ! is_account_locked "$user"; then
          should_be_locked+=("$user")
        fi
      fi
    done
  fi
}

query() {
  if [[ ${#should_be_locked[@]} -gt 0 ]]; then
    echo -e "${BLD} >>> ${YLW}$YO The following users should be regenerated (they have 'u!' directive but are unlocked):${NRM}"
    format_array should_be_locked
    printf "\n"
  else
    echo -e "${BLD} >>> $CHECKMARK User accounts on the live system are in parity with sysuser.d settings"
    if [[ -n "${delete[*]}" ]]; then
      printf "\n"

      locked_users=()
      active_users=()

      for user in "${delete[@]}"; do
        if is_account_locked "$user"; then
          locked_users+=("$user")
        else
          active_users+=("$user")
        fi
      done

      format_two_columns locked_users active_users "$LOCKED Locked/expired" "$UNLOCKED Unlocked/active"
      printf "\n"
    fi
  fi

  if [[ -n "${orphaned[*]}" ]]; then
    echo -e "${BLD} >>> ${YLW}$YO Users that have been orphaned by non-present packages:${NRM}"
    format_array orphaned
    printf "\n\n"
  else
    echo -e "${BLD} >>> $CHECKMARK No orphaned users present${NRM}"
  fi
}

do_fixup() {
  if [[ ${#should_be_locked[@]} -gt 0 ]]; then
    for i in "${should_be_locked[@]}"; do
      chage -E 1970-01-02 "$i"
    done
  fi

  if [[ ${#orphaned[@]} -gt 0 ]]; then
    for i in "${orphaned[@]}"; do
      local _homedir=$(getent passwd "$i" | awk -F: '{ print $6 }')
      userdel "$i"
      if [[ $_homedir = "/" ]]; then
        continue
      else
        echohomedir+=("$_homedir")
      fi
    done

    echo -e ${BLD}" >>> Optionally remove homedirs which have been intentionally left on the file system"${NRM}
    format_array echohomedir
    printf "\n\n"
  else
    echo -e "${BLD} >>> $NO No users need to be locked nor are there any orphaned users, nothing to do"${NRM}
  fi
}

case "$1" in
  q|Q|query|Query)
    findem && query
    ;;
  f|F|fix|Fix)
    findem && do_fixup
    ;;
  *)
    echo -e "${BLD}Usage: ${RED}$0${YLW} {query|fix}"${NRM}
    cat <<EOF

query : compare user status from sysuser.d files vs the live system, identify
        any orphaned users, then report findings
fix   : lock any user that should be locked per sysfiles.d files & delete any
        orphaned users
EOF
;;
esac
