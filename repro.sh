#!/usr/bin/env bash
# Reproducer for docker/buildx#3951: runs `docker buildx bake` with SSH agent
# forwarding, either answering "y" to the entitlement prompt or passing
# --allow=ssh, and records which runs lose the agent socket.
#
# Usage: ./repro.sh [-c CONTEXT]... [-t TARGET] [-m MODE]... [-n RUNS]
#   -c CONTEXT[:LABEL]  docker context(s) to build on (default: current
#               context). LABEL replaces the context name in logs/output.
#   -t TARGET   bake target: final (two ssh targets, default) or simple
#   -m MODE     prompt | flag (default: both)
#   -n RUNS     repeat each context/mode pair, interleaved (default: 1)
# Env:
#   BUILDX=...        buildx invocation (default: "docker buildx"); e.g. a
#                     standalone binary "./bin/docker-buildx-v0.34.1"
#   Bake variables (GIT_DEP_URL, GIT_FETCH_WITH_CLI, ...) pass through, see
#   docker-bake.hcl.
set -uo pipefail
cd "$(dirname "$0")"

contexts=() modes=() target=final runs=1
while getopts "c:t:m:n:" o; do
  case $o in
    c) contexts+=("$OPTARG") ;;
    t) target=$OPTARG ;;
    m) modes+=("$OPTARG") ;;
    n) runs=$OPTARG ;;
    *) sed -n "2,17p" "$0"; exit 2 ;;
  esac
done
((${#contexts[@]})) || contexts=("$(docker context show)")
((${#modes[@]})) || modes=(prompt flag)
read -r -a buildx <<<"${BUILDX:-docker buildx}"

mkdir -p logs
stamp=$(date +%Y%m%d-%H%M%S)

env_report() {
  echo "date:          $(date -Is)"
  echo "buildx:        $("${buildx[@]}" version 2>&1)"
  echo "docker client: $(docker version --format '{{.Client.Version}}' 2>&1)"
  echo "shell:         $SHELL"
  echo "SSH_AUTH_SOCK: ${SSH_AUTH_SOCK:-<unset>}"
  # Key size and type only: no fingerprints or comments (emails).
  echo "ssh-add -l:"; ssh-add -l 2>&1 | awk '{print "  key", $1, $NF}'
  local spec ctx host
  for spec in "${contexts[@]}"; do
    ctx=${spec%%:*}
    # Endpoint scheme only (ssh://, unix://, tcp://): no user, host or IP.
    host=$(docker context inspect "$ctx" --format '{{.Endpoints.docker.Host}}' 2>&1)
    echo "context $(label "$spec"): endpoint=${host%%://*}://<redacted>" \
         "server=$(docker --context "$ctx" version --format '{{.Server.Version}} {{.Server.Arch}}' 2>&1)" \
         "buildkit=$(docker --context "$ctx" buildx inspect 2>/dev/null | awk '/^BuildKit version:/{print $3; exit}')"
  done
}

label() { [[ $1 == *:* ]] && echo "${1#*:}" || echo "$1"; }

run() { # ctx[:label] mode iteration -> exit code
  local ctx=${1%%:*} name; name=$(label "$1")
  local mode=$2 i=$3 log="logs/$stamp-$name-$target-$mode-$i.log"
  local cmd=("${buildx[@]}" bake --progress=plain "$target")
  [[ $mode == flag ]] && cmd=("${buildx[@]}" bake --progress=plain --allow=ssh "$target")
  {
    echo "### context=$name mode=$mode"
    echo "### DOCKER_CONTEXT=$name ${cmd[*]}"
  } >"$log"
  if [[ $mode == prompt ]]; then
    # The entitlement prompt is only shown when stdin is a TTY: run under a
    # pseudo-terminal via script(1) and answer "y" once the prompt appears.
    local q; printf -v q '%q ' "${cmd[@]}"
    (sleep 8; echo y) | DOCKER_CONTEXT=$ctx script -qefc "$q" /dev/null >>"$log" 2>&1
  else
    DOCKER_CONTEXT=$ctx "${cmd[@]}" </dev/null >>"$log" 2>&1
  fi
  local rc=$?
  echo "### exit=$rc" >>"$log"
  # buildx prints the builder name, which for the docker driver is the context
  # name: swap it for the label so the log can be shared.
  [[ $name != "$ctx" ]] && sed -i "s/building with \"${ctx//./\\.}\" instance/building with \"${name}\" instance/" "$log"
  printf "%-12s %-8s %-7s #%-2s exit=%-3s %s\n" "$name" "$target" "$mode" "$i" "$rc" "$log"
  # Only build output lines (not the echoed RUN command text) + final error.
  tr -d '\r' <"$log" \
    | grep -E '^#[0-9]+ [0-9.]+ .*(\[(fetch-[ab]|simple)\] (OK|ssh-add)|cannot access|Permission denied|Host key verification)|^ERROR' \
    | cut -c1-160 | sed 's/^/    /'
  return $rc
}

env_report | tee "logs/$stamp-env.txt"
echo
declare -A failures=()
for ((i = 1; i <= runs; i++)); do
  for ctx in "${contexts[@]}"; do
    for mode in "${modes[@]}"; do
      run "$ctx" "$mode" "$i" || failures[$ctx/$mode]=$((${failures[$ctx/$mode]:-0} + 1))
    done
  done
done
echo
echo "summary ($target, $runs run(s) each):"
for ctx in "${contexts[@]}"; do
  for mode in "${modes[@]}"; do
    printf '  %-12s %-7s failed %s/%s\n' "$(label "$ctx")" "$mode" "${failures[$ctx/$mode]:-0}" "$runs"
  done
done
((${#failures[@]} == 0))
