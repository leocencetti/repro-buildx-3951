# syntax=docker/dockerfile:1.10
# `fetch`: cargo fetches a git dependency over SSH through the forwarded agent.
# `clone`: plain `git clone` over SSH (the single-target layout from the issue).
#
# GitHub requires a registered key for SSH access even to public repos, so the
# public default dependency is enough to exercise agent forwarding.
# Key comments and fingerprints are stripped from the ssh-add output so that
# logs can be shared.

FROM build-base AS fetch
ARG STEP_NAME=fetch

# Token-or-agent switch: CI passes a token secret, local builds use the agent.
RUN --mount=type=secret,id=GITHUB_AUTH_TOKEN,env=GITHUB_AUTH_TOKEN,required=false \
    if [ "${GITHUB_AUTH_TOKEN}" != "" ]; then \
      git config --global url."https://x-access-token:${GITHUB_AUTH_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"; \
      git config --global --add url."https://x-access-token:${GITHUB_AUTH_TOKEN}@github.com/".insteadOf "git@github.com:"; \
    else echo "Using SSH agent for repository access"; fi

# true = cargo shells out to git/ssh; false = built-in libgit2.
ARG GIT_FETCH_WITH_CLI=true
ENV CARGO_NET_GIT_FETCH_WITH_CLI=${GIT_FETCH_WITH_CLI}
ENV CARGO_TERM_VERBOSE=true

# Throwaway crate whose only dependency is the SSH git repo.
ARG GIT_DEP_URL
ARG GIT_DEP_CRATE
WORKDIR /ws/consumer
RUN mkdir -p src && : > src/lib.rs && \
    printf '[package]\nname = "consumer"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\ndep = { package = "%s", git = "%s" }\n' \
      "${GIT_DEP_CRATE}" "${GIT_DEP_URL}" > Cargo.toml && \
    cat Cargo.toml

RUN --mount=type=ssh \
    echo "[${STEP_NAME}] SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-<unset>} CARGO_NET_GIT_FETCH_WITH_CLI=${CARGO_NET_GIT_FETCH_WITH_CLI}" \
    && (ls -l "${SSH_AUTH_SOCK:-/nonexistent}" || true) \
    && (keys="$(ssh-add -l)" \
        && echo "$keys" | awk -v s="[${STEP_NAME}]" '{print s, "ssh-add: key", $1, $NF}' \
        || echo "[${STEP_NAME}] ssh-add -l exit=$?") \
    && install -m 0700 -d ~/.ssh \
    && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null \
    && cargo fetch \
    && echo "[${STEP_NAME}] OK $(grep -m1 'source = "git+' Cargo.lock)" | tee /ws/result.txt

FROM build-base AS clone
ARG STEP_NAME=clone
ARG CLONE_REPO
WORKDIR /ws
RUN --mount=type=ssh \
    echo "[${STEP_NAME}] SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-<unset>}" \
    && (keys="$(ssh-add -l)" \
        && echo "$keys" | awk -v s="[${STEP_NAME}]" '{print s, "ssh-add: key", $1, $NF}' \
        || echo "[${STEP_NAME}] ssh-add -l exit=$?") \
    && install -m 0700 -d ~/.ssh \
    && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null \
    && git clone --depth 1 "git@github.com:${CLONE_REPO}.git" /ws/repo \
    && echo "[${STEP_NAME}] OK $(git -C /ws/repo rev-parse --short HEAD)" | tee /ws/result.txt
