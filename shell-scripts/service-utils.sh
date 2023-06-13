#!/bin/bash

function getDirNames() {
  base_dir_expanded="$1/*/"
  index=0
  for dir in $base_dir_expanded; do dir_names[index]=$(basename "$dir") && ((index++)); done
  jq --compact-output --null-input '$ARGS.positional' --args -- "${dir_names[@]}"
}
