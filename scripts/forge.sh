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

# The project identifier for a given arm, without the trailing newline — the form every verb below
# interpolates into an endpoint. `verb_slug` is the same value with a newline, for humans.
slug_value() {
  local arm="$1" path
  path=$(remote_path)
  if [ -z "$path" ]; then
    echo "forge: no origin remote — cannot name the project on '$ROOT'." >&2
    exit 1
  fi
  case "$arm" in
    github)
      # owner/repo, exactly as `gh` takes it for --repo.
      printf '%s' "$path" ;;
    gitlab)
      # The WHOLE path, URL-encoded: GitLab projects nest in subgroups (`group/sub/project`) and
      # `projects/:id` wants that path percent-encoded. A slug that assumed two segments would
      # address the wrong project — or none — on every subgrouped repository.
      printf '%s' "$path" | sed 's#/#%2F#g' ;;
  esac
}

verb_slug() {
  [ $# -eq 0 ] || die_usage "slug takes no arguments"
  local arm
  arm=$(arm_or_die)
  slug_value "$arm"
  echo
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

# ------------------------------------------------------------------------------- normalisation
#
# The two payload shapes, and the ONE shape the skills see. Every disagreement between the forges
# is spent here and nowhere else — `number`/`iid`, `OPEN`/`opened`, `[{name}]`/`[string]`,
# `url`/`web_url`, `updatedAt`/`updated_at`. A caller that had to know which spelling it was
# holding would be a caller that has to know which forge it is on, which is the thing this file
# exists to abolish.
NORM_ISSUE_GH='{number:.number,title:.title,body:(.body//""),state:(.state|ascii_downcase),labels:[.labels[]?|.name],url:.url,updatedAt:.updatedAt}'
NORM_ISSUE_GL='{number:.iid,title:.title,body:(.description//""),state:(if .state=="opened" then "open" else (.state|ascii_downcase) end),labels:(.labels//[]),url:.web_url,updatedAt:.updated_at}'

forge_fail() { printf 'forge: %s\n' "$1" >&2; exit 1; }

# Project the normalised object (or array of them) onto the requested --fields, in the order they
# were asked for. Empty --fields means "everything the normaliser produces".
project() {
  local fields="$1"
  if [ -z "$fields" ]; then cat; return 0; fi
  jq --argjson k "$(printf '%s' "$fields" | jq -R 'split(",")')" '
    def pick($o): reduce $k[] as $x ({}; .[$x] = $o[$x]);
    if type == "array" then map(. as $o | pick($o)) else . as $o | pick($o) end'
}

# ------------------------------------------------------------------------------- issue verbs

# Shared option parsing. Every issue verb draws from the same small set, so it is read once rather
# than six times — a per-verb parser is how `--body-file` ends up meaning something subtly
# different depending on which verb you reached it through.
ISSUE_FIELDS=""; ISSUE_STATE=""; ISSUE_SEARCH=""; ISSUE_LIMIT=""
ISSUE_TITLE=""; ISSUE_BODY_FILE=""; ISSUE_COMMENT=""
ISSUE_LABELS=""            # comma-joined, for the GitLab REST arm
GH_LABEL_ARGS=()           # repeated --label, for the gh porcelain arm

parse_issue_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --fields)    [ $# -ge 2 ] || die_usage "--fields needs a value";    ISSUE_FIELDS="$2"; shift 2 ;;
      --state)     [ $# -ge 2 ] || die_usage "--state needs a value";     ISSUE_STATE="$2";  shift 2 ;;
      --search)    [ $# -ge 2 ] || die_usage "--search needs a value";    ISSUE_SEARCH="$2"; shift 2 ;;
      --limit)     [ $# -ge 2 ] || die_usage "--limit needs a value";     ISSUE_LIMIT="$2";  shift 2 ;;
      --title)     [ $# -ge 2 ] || die_usage "--title needs a value";     ISSUE_TITLE="$2";  shift 2 ;;
      --comment)   [ $# -ge 2 ] || die_usage "--comment needs a value";   ISSUE_COMMENT="$2"; shift 2 ;;
      --body-file) [ $# -ge 2 ] || die_usage "--body-file needs a value"
                   [ -r "$2" ] || die_usage "--body-file '$2' is not readable"
                   ISSUE_BODY_FILE="$2"; shift 2 ;;
      --label|--add-label)
                   [ $# -ge 2 ] || die_usage "$1 needs a value"
                   if [ -z "$ISSUE_LABELS" ]; then ISSUE_LABELS="$2"; else ISSUE_LABELS="$ISSUE_LABELS,$2"; fi
                   GH_LABEL_ARGS+=("$1" "$2"); shift 2 ;;
      *) die_usage "unknown option for issue: $1" ;;
    esac
  done
}

# GitLab spells the open state `opened`; the kit says `open`. One translation, one home.
gl_state() {
  case "$1" in
    open)   printf 'opened' ;;
    closed) printf 'closed' ;;
    all)    printf 'all' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Every WRITE goes in as a JSON document on stdin (`--input -`), never as repeated `-f key=value`
# flags. Two reasons, both load-bearing: `gh -f` and `glab -f` do not agree on type coercion, and
# an issue body containing newlines — which every body this kit writes does — cannot survive either
# spelling intact.
gl_write() {   # gl_write <endpoint> <method> <json-payload>
  printf '%s' "$3" | glab api "$1" --method "$2" --input -
}

verb_issue() {
  local sub="${1:-}"; [ -n "$sub" ] || die_usage "issue needs a sub-verb"
  shift
  local num=""
  case "$sub" in
    view|edit|comment|reopen)
      num="${1:-}"
      case "$num" in ''|*[!0-9]*) die_usage "issue $sub needs an issue number" ;; esac
      shift ;;
  esac
  parse_issue_opts "$@"

  local arm slug raw url payload
  arm=$(arm_or_die)
  # `templates` is answered from the working tree, so it needs no project identifier — asking for
  # one would refuse in a repository whose remote is absent but whose templates are right there.
  if [ "$sub" != "templates" ]; then slug=$(slug_value "$arm"); fi

  case "$sub" in
    view)
      if [ "$arm" = "github" ]; then
        raw=$(gh issue view "$num" --repo "$slug" \
              --json number,title,body,state,labels,url,updatedAt) \
          || forge_fail "gh issue view $num failed"
        printf '%s' "$raw" | jq "$NORM_ISSUE_GH" | project "$ISSUE_FIELDS"
      else
        raw=$(glab api "projects/$slug/issues/$num") \
          || forge_fail "glab api projects/$slug/issues/$num failed"
        printf '%s' "$raw" | jq "$NORM_ISSUE_GL" | project "$ISSUE_FIELDS"
      fi ;;

    list)
      if [ "$arm" = "github" ]; then
        set -- issue list --repo "$slug" --json number,title,body,state,labels,url,updatedAt
        [ -n "$ISSUE_STATE" ]  && set -- "$@" --state "$ISSUE_STATE"
        [ -n "$ISSUE_SEARCH" ] && set -- "$@" --search "$ISSUE_SEARCH"
        [ -n "$ISSUE_LIMIT" ]  && set -- "$@" --limit "$ISSUE_LIMIT"
        set -- "$@" ${GH_LABEL_ARGS[@]+"${GH_LABEL_ARGS[@]}"}
        raw=$(gh "$@") || forge_fail "gh issue list failed"
        printf '%s' "$raw" | jq "map($NORM_ISSUE_GH)" | project "$ISSUE_FIELDS"
      else
        local q="projects/$slug/issues?per_page=${ISSUE_LIMIT:-100}"
        [ -n "$ISSUE_STATE" ]  && q="$q&state=$(gl_state "$ISSUE_STATE")"
        [ -n "$ISSUE_LABELS" ] && q="$q&labels=$ISSUE_LABELS"
        [ -n "$ISSUE_SEARCH" ] && q="$q&search=$ISSUE_SEARCH"
        raw=$(glab api "$q") || forge_fail "glab api $q failed"
        printf '%s' "$raw" | jq "map($NORM_ISSUE_GL)" | project "$ISSUE_FIELDS"
      fi ;;

    create)
      [ -n "$ISSUE_TITLE" ] || die_usage "issue create needs --title"
      [ -n "$ISSUE_BODY_FILE" ] || die_usage "issue create needs --body-file"
      if [ "$arm" = "github" ]; then
        url=$(gh issue create --repo "$slug" --title "$ISSUE_TITLE" \
              --body-file "$ISSUE_BODY_FILE" ${GH_LABEL_ARGS[@]+"${GH_LABEL_ARGS[@]}"}) \
          || forge_fail "gh issue create failed"
        jq -n --arg url "$url" '{number: ($url | split("/") | last | tonumber), url: $url}'
      else
        payload=$(jq -n --arg t "$ISSUE_TITLE" --rawfile d "$ISSUE_BODY_FILE" --arg l "$ISSUE_LABELS" \
          '{title:$t, description:$d} + (if $l == "" then {} else {labels:$l} end)')
        raw=$(gl_write "projects/$slug/issues" POST "$payload") \
          || forge_fail "glab issue create failed"
        printf '%s' "$raw" | jq '{number:.iid, url:.web_url}'
      fi ;;

    edit)
      if [ "$arm" = "github" ]; then
        set -- issue edit "$num" --repo "$slug"
        [ -n "$ISSUE_BODY_FILE" ] && set -- "$@" --body-file "$ISSUE_BODY_FILE"
        set -- "$@" ${GH_LABEL_ARGS[@]+"${GH_LABEL_ARGS[@]}"}
        gh "$@" >/dev/null || forge_fail "gh issue edit $num failed"
      else
        payload=$(jq -n --arg l "$ISSUE_LABELS" --arg bf "$ISSUE_BODY_FILE" '
          (if $bf == "" then {} else {description: $bf} end)
          + (if $l == "" then {} else {add_labels: $l} end)')
        # The body is read as a raw file rather than interpolated as a path.
        if [ -n "$ISSUE_BODY_FILE" ]; then
          payload=$(jq -n --rawfile d "$ISSUE_BODY_FILE" --arg l "$ISSUE_LABELS" \
            '{description:$d} + (if $l == "" then {} else {add_labels:$l} end)')
        fi
        gl_write "projects/$slug/issues/$num" PUT "$payload" >/dev/null \
          || forge_fail "glab issue edit $num failed"
      fi
      jq -n --argjson n "$num" '{number:$n}' ;;

    comment)
      [ -n "$ISSUE_BODY_FILE" ] || die_usage "issue comment needs --body-file"
      if [ "$arm" = "github" ]; then
        url=$(gh issue comment "$num" --repo "$slug" --body-file "$ISSUE_BODY_FILE") \
          || forge_fail "gh issue comment $num failed"
        jq -n --arg url "$url" '{url:$url}'
      else
        payload=$(jq -n --rawfile b "$ISSUE_BODY_FILE" '{body:$b}')
        raw=$(gl_write "projects/$slug/issues/$num/notes" POST "$payload") \
          || forge_fail "glab issue comment $num failed"
        # A GitLab note carries no web URL of its own; the anchor on the issue page is the
        # addressable thing, so it is built here rather than handing the caller a null.
        printf '%s' "$raw" | jq --arg base "https://$(arm_host)/$(remote_path)/-/issues/$num" \
          '{url: ($base + "#note_" + (.id|tostring))}'
      fi ;;

    reopen)
      if [ "$arm" = "github" ]; then
        set -- issue reopen "$num" --repo "$slug"
        [ -n "$ISSUE_COMMENT" ] && set -- "$@" --comment "$ISSUE_COMMENT"
        gh "$@" >/dev/null || forge_fail "gh issue reopen $num failed"
        jq -n --argjson n "$num" '{number:$n, state:"open"}'
      else
        payload=$(jq -n --arg c "$ISSUE_COMMENT" \
          '{state_event:"reopen"} + (if $c == "" then {} else {} end)')
        raw=$(gl_write "projects/$slug/issues/$num" PUT "$payload") \
          || forge_fail "glab issue reopen $num failed"
        if [ -n "$ISSUE_COMMENT" ]; then
          gl_write "projects/$slug/issues/$num/notes" POST \
            "$(jq -n --arg b "$ISSUE_COMMENT" '{body:$b}')" >/dev/null \
            || forge_fail "glab issue reopen $num: the note failed"
        fi
        printf '%s' "$raw" | jq '{number:.iid, state:"open"}'
      fi ;;

    templates)
      # Read off the working tree, not the API: both forges keep templates as committed files, and
      # create-issue Step 4 wants the paths so it can read the forms themselves.
      local dir
      if [ "$arm" = "github" ]; then dir="$ROOT/.github/ISSUE_TEMPLATE"; else dir="$ROOT/.gitlab/issue_templates"; fi
      # An absent directory is an empty answer with a zero exit — a repository may legitimately
      # carry no templates, and create-issue falls back to house style rather than refusing.
      [ -d "$dir" ] || return 0
      find "$dir" -maxdepth 1 -type f | LC_ALL=C sort ;;

    *) die_usage "unknown issue sub-verb: $sub" ;;
  esac
}

# --------------------------------------------------------------------------------------- dispatch
case "$VERB" in
  kind)  verb_kind "$@" ;;
  slug)  verb_slug "$@" ;;
  auth)  verb_auth "$@" ;;
  issue) verb_issue "$@" ;;
  *)     die_usage "unknown verb: $VERB" ;;
esac
