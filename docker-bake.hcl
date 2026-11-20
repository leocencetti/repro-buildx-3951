# Reproducer for docker/buildx#3951.
#
#   final            no ssh; the requested target
#   ├── fetch-a      ssh + cargo git dependency (linked via contexts = "target:...")
#   └── fetch-b      ssh + cargo git dependency (linked via contexts = "target:...")
#         └── build-base
#
#   simple           control: single ssh target doing a plain `git clone`

# Any repo works as long as it is fetched over ssh:// (GitHub needs a key for
# SSH even on public repos). Point these at a private repo if you prefer.
variable "GIT_DEP_URL" {
  description = "Cargo git dependency fetched over SSH by fetch-a / fetch-b."
  default     = "ssh://git@github.com/rust-lang/cfg-if"
}

variable "GIT_DEP_CRATE" {
  description = "Package name of the crate at GIT_DEP_URL."
  default     = "cfg-if"
}

variable "CLONE_REPO" {
  description = "GitHub repo (owner/name) cloned over SSH by the 'simple' target."
  default     = "rust-lang/cfg-if"
}

# Empty => use the SSH agent; set => use a token secret instead (CI path).
variable "GITHUB_AUTH_TOKEN" {
  default = ""
}

variable "GIT_FETCH_WITH_CLI" {
  description = "CARGO_NET_GIT_FETCH_WITH_CLI inside the fetch steps."
  default     = "true"
}

group "default" {
  targets = ["final"]
}

target "build-base" {
  dockerfile = "docker/shards/base.Dockerfile"
  target     = "build-base"
}

target "_ssh" {
  ssh = GITHUB_AUTH_TOKEN == "" ? [{ id = "default" }] : []
  secret = GITHUB_AUTH_TOKEN == "" ? [] : [
    {
      type = "env"
      id   = "GITHUB_AUTH_TOKEN"
    }
  ]
  contexts = { build-base = "target:build-base" }
}

target "_fetch" {
  inherits        = ["_ssh"]
  dockerfile      = "docker/shards/fetch.Dockerfile"
  target          = "fetch"
  no-cache-filter = ["fetch"] # always re-run the SSH step, keep the toolchain cached
  args = {
    GIT_DEP_URL        = GIT_DEP_URL
    GIT_DEP_CRATE      = GIT_DEP_CRATE
    GIT_FETCH_WITH_CLI = GIT_FETCH_WITH_CLI
  }
}

target "fetch-a" {
  inherits = ["_fetch"]
  args     = { STEP_NAME = "fetch-a" }
}

target "fetch-b" {
  inherits = ["_fetch"]
  args     = { STEP_NAME = "fetch-b" }
}

target "final" {
  dockerfile      = "docker/shards/final.Dockerfile"
  target          = "final"
  output          = ["type=cacheonly"]
  no-cache-filter = ["final"]
  contexts = {
    fetch-a = "target:fetch-a"
    fetch-b = "target:fetch-b"
  }
}

target "simple" {
  inherits        = ["_ssh"]
  dockerfile      = "docker/shards/fetch.Dockerfile"
  target          = "clone"
  no-cache-filter = ["clone"]
  args            = { CLONE_REPO = CLONE_REPO, STEP_NAME = "simple" }
  output          = ["type=cacheonly"]
}
