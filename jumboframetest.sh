#!/bin/bash

# define the name or IP address of the machine that will receive the file
HOST=workbench.lan

# define the user you are running as on both machines
USER=$(whoami)

# define a link to tmpfs where there is plenty of RAM free
TMPFS=/scratch

# log file with results
LOG=$TMPFS/jumboframe.csv
LOG2=$TMPFS/jumboframe.for.histogram.csv

make_test_files() {
  # make 5 x 10 MB blocks
  parallel "dd if=/dev/urandom of=$TMPFS/block{} bs=1M count=10 &>/dev/null" ::: 1 2 3 4 5

  for j in {10..19}; do
    # pseudo random order of the 10 MB blocks to get a 10 x 33 MB whole file
    for i in {0..32}; do
      RND=$(( 1 + $((  RANDOM % 5 )) ))
      Array[$i]="$TMPFS/block$RND"
    done
    cat "${Array[@]}" > "$TMPFS/whole$j"

  done
  rm -f $TMPFS/block*
}

run_test() {
  for payload in "$TMPFS"/whole1*; do
    start=$(date +%s.%N)
    rsync -a "$payload" "$USER@$HOST:/tmp"
    end=$(date +%s.%N)
    diff=$(echo "scale=6; $end - $start" | bc)

    echo "$diff" >> $LOG2

    # clean up
    rm -f "$payload"
    ssh $HOST "rm -f /tmp${payload#$TMPFS}"
  done
}

case "$1" in
  rt|run-test)
    make_test_files
    run_test
    ;;
  f|files-only)
    make_test_files
    ;;
  *)
    echo "Usage: $0 {run-test|files-only}"
    ;;
esac

# vim:set ts=2 sw=2 et:
