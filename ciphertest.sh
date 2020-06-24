#!/bin/bash

# define the name or IP address of the machine that will receive the files
HOST=cloud

# define the user you are running as on both machines
USER=graysky

# define a link to tmpfs where there is plenty of RAM free
# by default /tmp is mounted with 1/2 physical memory and this test as written below
# requires approx 1.2G of free space on each end of the test
TMPFS=/scratch

# log file with results
#LOGPATH=/home/$USER
LOG=$TMPFS/cipher_results.csv

# all supported ciphers in 7.4p1
CIPHERS=(
'aes128-ctr'
'aes192-ctr'
'aes256-ctr'
'aes128-gcm@openssh.com'
'aes256-gcm@openssh.com'
'chacha20-poly1305@openssh.com'
)

####

# check deps
for i in dd parallel; do
  command -v $i >/dev/null 2>&1 || {
  echo " I require $i but it's not installed. Aborting!" >&2; exit 1; }
done

if ! ping -c 1 $HOST > /dev/null; then
  echo "$HOST is down"
  exit 1
fi

make_receipe() {
  # make 1100M file assembled from 3x10M files in in a pseudo random fashion
  for i in {0..109}; do
    RND=$(echo $[ 1 + $[ RANDOM % 3 ]])
    Array[$i]=$TMPFS/file$RND
  done
}

run_cipher_test() {
  for cipher in "${CIPHERS[@]}"; do
    echo " --> $cipher"
    parallel "dd if=/dev/urandom of=$TMPFS/file{} bs=1M count=10 &>/dev/null" ::: 1 2 3

    for j in 1 2 3; do
      make_receipe
      cat "${Array[@]}" > "$TMPFS/part$j"
      start=$(date +%s.%N)
      scp -c "$cipher" $TMPFS/part$j $USER@$HOST:$TMPFS
    end=$(date +%s.%N)
    diff=$(echo "scale=6; $end - $start" | bc)
    [[ ! -f $LOG ]] && echo "cipher,round,time(sec),host" > $LOG
    echo "$cipher,$j,$diff,$HOST" >> $LOG
    rm -f $TMPFS/part$j
    ssh $HOST "rm -f $TMPFS/part$j"
  done
done
rm -f $TMPFS/file[1,2,3]
}

make_test_files() {
  parallel "dd if=/dev/urandom of=$TMPFS/file{} bs=1M count=10 &>/dev/null" ::: 1 2 3
  for j in 1 2 3; do
    make_receipe
    cat "${Array[@]}" > "$TMPFS/part$j"
  done
}

case "$1" in
  c|cipher)
    run_cipher_test
    ;;
  f|files-only)
    make_test_files
    ;;
  *)
    echo "Usage: $0 {cipher|files-only}"
    ;;
esac

# vim:set ts=2 sw=2 et:
