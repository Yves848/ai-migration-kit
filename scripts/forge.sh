#!/usr/bin/env bash
# forge.sh — the kit's forge dispatcher (#1).
#
# The core lifecycle skills (create-issue, implement-issue, merge-pr) used to name `gh` at 203 call
# sites across 21 files, and skills/_shared/preconditions.md refused every non-GitHub tracker by
# design. This script is the one translation layer that replaces both: it resolves which forge this
# repository lives on, then serves a fixed verb vocabulary whose OUTPUT SHAPE IS THE KIT'S OWN —
# not gh's, not glab's. Callers stop knowing which forge they are on.
#
# Why a normalising dispatcher rather than a per-call-site command mapping. The expensive part of
# speaking two forges is not translating commands, it is the handful of places the two disagree
# SEMANTICALLY — a draft is a boolean field on GitHub and a `Draft: ` title prefix on GitLab;
# `mergeStateStatus` has no GitLab counterpart, only the finer-grained `detailed_merge_status`;
# review threads are a GraphQL connection on one side and REST discussions on the other. Mapped at
# each call site, those become 21 independent judgement calls that no single test can hold. Mapped
# here, each is one function with one golden case per arm (tests/forge/test.sh).
#
# The doctrine — the full vocabulary, the normalised shapes, the gap tables, and what degrades on
# GitLab — lives in skills/_shared/forge.md. This file implements it; it does not restate it.
#
# Usage:
#   forge.sh [-C <repo-path>] <verb> [args...]
#
#   -C <repo-path>  anywhere in the repository. Default: the current directory. Never `cd`s.
#
# Verbs (this file, Task 1 of #1's plan):
#   kind    print the arm — `github` or `gitlab`
#   slug    print the project identifier the arm's API wants:
#             github → owner/repo
#             gitlab → the FULL project path, URL-encoded (subgroups included), for projects/:id
#   auth    print the authenticated login, or exit 1 naming the remedy for THIS arm and THIS host
#
# Exit codes:
#   0  success
#   1  the operation failed (message, and where useful a remedy, on stderr)
#   2  bad invocation — no verb, an unknown verb, or a -C that is not a repository. "The question
#      was never asked" is deliberately NOT the same code as "the question was asked and has no
#      answer" (3): the shared-preconditions reference branches on the difference.
#   3  UNKNOWN_FORGE — neither the profile nor the remote establishes an arm. Never a guess: a
#      wrong guess here routes real writes (a merge, an issue edit) at the wrong forge.
set -euo pipefail

REPO_DIR="."

usage() {
  cat >&2 <<'USAGE'
usage: forge.sh [-C <repo-path>] <verb> [args...]

verbs:
  kind    print the forge arm — github | gitlab
  slug    print the project identifier this arm's API wants
  auth    print the authenticated login, or exit 1 with the remedy

exit: 0 ok · 1 operation failed · 2 bad invocation · 3 UNKNOWN_FORGE
USAGE
}

die_usage() { [ -n "${1:-}" ] && printf 'forge: %s\n' "$1" >&2; usage; exit 2; }

# ------------------------------------------------------------------------------ argument parsing
while [ $# -gt 0 ]; do
  case "$1" in
    -C)
      [ $# -ge 2 ] || die_usage "-C needs a path"
      REPO_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 2 ;;
    --) shift; break ;;
    -*) die_usage "unknown option: $1" ;;
    *) break ;;
  esac
done

VERB="${1:-}"
[ -n "$VERB" ] || die_usage "no verb given"
shift

# ------------------------------------------------------------------------------ repository anchor
#
# Resolved BEFORE dispatch so that "-C points at something that is not a repository" is reported as
# the bad invocation it is (2), rather than surfacing later as an empty remote and being misread as
# UNKNOWN_FORGE (3). No verdict was reached in that case, and no verdict is not a verdict.
ROOT=$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null) \
  || die_usage "-C '$REPO_DIR' is not inside a git repository"

# ------------------------------------------------------------------------------- the Tracker line
#
# Two spellings of this line exist in the tree and both are legitimate: the committed-profile form
# the template documents (`- **Tracker:** github (github.com) — …`) and the plain form
# skills/profile-repo/scripts/repo-profile.sh's `detect` emits (`tracker: github (github.com)`). A
# parser that knows only one of them fails on half the profiles in the wild, so `*` is stripped and
# the match is case-insensitive.
PROFILE="$ROOT/.claude/skills/repo-profile.md"
TRACKER_REST=""
if [ -r "$PROFILE" ]; then
  _line=$(grep -i -m1 'tracker:' "$PROFILE" 2>/dev/null || true)
  if [ -n "$_line" ]; then
    TRACKER_REST=$(printf '%s' "$_line" | sed -E 's/\*//g' | sed -E 's/.*[Tt]racker:[[:space:]]*//')
  fi
fi

profile_kind() {
  [ -n "$TRACKER_REST" ] || return 0
  printf '%s' "$TRACKER_REST" | sed -E 's/[[:space:]].*$//' | tr '[:upper:]' '[:lower:]'
}

profile_host() {
  [ -n "$TRACKER_REST" ] || return 0
  printf '%s' "$TRACKER_REST" | sed -n 's/^[A-Za-z]*[[:space:]]*(\([^)]*\)).*/\1/p'
}

# ---------------------------------------------------------------------------------- the remote
#
# The three remote-URL shapes, in the order and spelling skills/profile-repo/scripts/repo-profile.sh
# already uses (its own comment records why a single pattern was not enough): `ssh://[user@]host[:port]/…`,
# `http(s)://[user[:token]@]host[:port]/…` — a CI checkout token embeds credentials right there —
# and the scp-like `git@host:owner/repo`. Reused verbatim rather than written a fourth time.
ORIGIN_URL=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)

remote_host() {
  [ -n "$ORIGIN_URL" ] || return 0
  printf '%s\n' "$ORIGIN_URL" | sed -E \
    -e 's#^ssh://([^@/]+@)?([^/:]+)(:[0-9]+)?/.*#\2#' \
    -e 's#^(https?)://([^@/]+@)?([^/:]+)(:[0-9]+)?/.*#\3#' \
    -e 's#^git@([^:]+):.*#\1#'
}

remote_path() {
  [ -n "$ORIGIN_URL" ] || return 0
  printf '%s\n' "$ORIGIN_URL" | sed -E \
    -e 's#^ssh://([^@/]+@)?[^/:]+(:[0-9]+)?/##' \
    -e 's#^https?://([^@/]+@)?[^/:]+(:[0-9]+)?/##' \
    -e 's#^git@[^:]+:##' \
    -e 's#\.git$##' \
    -e 's#/+$##'
}

# ------------------------------------------------------------------------------- arm resolution
#
# Precedence, and why. The profile's Tracker line wins outright: it is committed data the owner
# reviewed (ADR-0001), and a remote can legitimately disagree with it — a repo moved between hosts
# keeps a stale `origin` for a while, and letting that stale value win is precisely how work gets
# filed on the wrong server. Only when the profile is absent, or its Tracker line is still a TODO,
# does the remote decide.
#
# The remote is then read in decreasing order of certainty: the two names that can only mean one
# thing, then an authentication probe. The probe is the same shape repo-profile.sh's own Tracker
# section uses — it takes `gh repo view` succeeding against THIS remote as the positive signal
# rather than a literal string match — because a self-hosted GitLab is routinely called something
# like `git.acme.io`, which no name rule can place.
resolve_arm() {
  local pk host
  pk=$(profile_kind)
  case "$pk" in
    github|gitlab) printf '%s' "$pk"; return 0 ;;
  esac

  host=$(remote_host)
  [ -n "$host" ] || return 3

  case "$host" in
    github.com) printf 'github'; return 0 ;;
    gitlab.com|gitlab.*) printf 'gitlab'; return 0 ;;
  esac

  if command -v glab >/dev/null 2>&1 && glab auth status --hostname "$host" >/dev/null 2>&1; then
    printf 'gitlab'; return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh auth status --hostname "$host" >/dev/null 2>&1; then
    printf 'github'; return 0
  fi
  return 3
}

arm_or_die() {
  local arm rc=0
  arm=$(resolve_arm) || rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$arm" ]; then
    {
      echo "forge: UNKNOWN_FORGE — cannot tell which forge '$ROOT' lives on."
      if [ -z "$ORIGIN_URL" ]; then
        echo "       No origin remote, and no usable Tracker line in .claude/skills/repo-profile.md."
      else
        echo "       origin is '$ORIGIN_URL' (host '$(remote_host)'), which neither name nor an"
        echo "       authenticated gh/glab could place."
      fi
      echo "       Fix: add a Tracker line to .claude/skills/repo-profile.md — 'tracker: github (<host>)'"
      echo "       or 'tracker: gitlab (<host>)' — or authenticate the matching CLI against that host."
      echo "       Refusing to guess: a wrong arm routes real writes at the wrong forge."
    } >&2
    exit 3
  fi
  printf '%s' "$arm"
}

# The host the arm talks to. The profile's parenthesised host wins when it is there (same argument
# as the arm itself); otherwise the remote's.
arm_host() {
  local h
  h=$(profile_host)
  [ -n "$h" ] || h=$(remote_host)
  printf '%s' "$h"
}

# ---------------------------------------------------------------------------------------- verbs

verb_kind() {
  [ $# -eq 0 ] || die_usage "kind takes no arguments"
  arm_or_die
  echo
}

verb_slug() {
  [ $# -eq 0 ] || die_usage "slug takes no arguments"
  local arm path
  arm=$(arm_or_die)
  path=$(remote_path)
  if [ -z "$path" ]; then
    echo "forge: no origin remote — cannot name the project on '$ROOT'." >&2
    exit 1
  fi
  case "$arm" in
    github)
      # owner/repo, exactly as `gh` takes it for --repo.
      printf '%s\n' "$path" ;;
    gitlab)
      # The WHOLE path, URL-encoded: GitLab projects nest in subgroups (`group/sub/project`) and
      # `projects/:id` wants that path percent-encoded. A slug that assumed two segments would
      # address the wrong project — or none — on every subgrouped repository.
      printf '%s\n' "$path" | sed 's#/#%2F#g' ;;
  esac
}

verb_auth() {
  [ $# -eq 0 ] || die_usage "auth takes no arguments"
  local arm host out rc=0
  arm=$(arm_or_die)
  host=$(arm_host)

  # Both arms ask the API rather than the CLI's own `auth status`, and normalise with jq here
  # rather than with a `--jq`/`--output` flag: those flags differ between the two CLIs and have
  # moved between glab versions, while the REST payload has not. One shape in, one field out.
  case "$arm" in
    github)
      command -v gh >/dev/null 2>&1 || {
        echo "forge: the arm is github but 'gh' is not on PATH — see requirements.json." >&2; exit 1; }
      out=$(gh api user 2>/dev/null | jq -r '.login // empty') || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        {
          echo "forge: not authenticated against '$host' (github arm)."
          echo "       Fix: gh auth login -h $host"
        } >&2
        exit 1
      fi
      printf '%s\n' "$out" ;;
    gitlab)
      command -v glab >/dev/null 2>&1 || {
        echo "forge: the arm is gitlab but 'glab' is not on PATH — see requirements.json." >&2; exit 1; }
      out=$(glab api user 2>/dev/null | jq -r '.username // empty') || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        {
          echo "forge: not authenticated against '$host' (gitlab arm)."
          echo "       Fix: glab auth login --hostname $host"
        } >&2
        exit 1
      fi
      printf '%s\n' "$out" ;;
  esac
}

# --------------------------------------------------------------------------------------- dispatch
case "$VERB" in
  kind) verb_kind "$@" ;;
  slug) verb_slug "$@" ;;
  auth) verb_auth "$@" ;;
  *)    die_usage "unknown verb: $VERB" ;;
esac
