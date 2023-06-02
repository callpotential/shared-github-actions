#!/bin/bash

function getServiceNames() {
  index=0
  for dir in $1; do service_names[index]=$(basename "$dir") && ((index++)); done

  jq --compact-output --null-input '$ARGS.positional' --args -- "${service_names[@]}"
}
