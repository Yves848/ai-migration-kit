#!/usr/bin/env bash
# Golden test for scripts/forge.sh — the forge dispatcher (#1).
#
# The seam is forge.sh's OWN exit code and stdout, observed with a stubbed `gh` and a stubbed
# `glab` placed ahead of the real ones on PATH ($WORK/bin, the tests/survey/test.sh pattern) and a
# fabricated .claude/skills/repo-profile.md supplying the Tracker line. Nothing here reaches into a
# helper function: the contract the three core lifecycle skills depend on is what forge.sh PRINTS
# and what it EXITS with, and that is the only thing asserted.
#
# Task 1's scope: arm resolution plus the `kind`, `slug` and `auth` verbs. The arm is the routing
# decision every later verb inherits, so it is proven first and on its own — a `kind` that guesses
# would make every downstream assertion meaningless while still looking green.
#
# Why the stubs reject unknown flags (the tests/survey/test.sh §gh-stub lesson, #452): a stub that
# accepts anything unconditionally keeps passing while the real invocation breaks. Each stub below
# only answers the invocations forge.sh is allowed to make, and rejects the rest the way the real
# CLI does.
set -euo pipefail
cd "$(dirname "$0")/../.."
KIT="$PWD"
FORGE="$KIT/scripts/forge.sh"

. "$KIT/tests/_lib.sh" || {
  echo "FAIL: cannot source $KIT/tests/_lib.sh — refusing to run unguarded"; exit 1; }
kit_init "$KIT"
# Decided, not omitted (tests/_lib.sh's contract). This suite only ever writes into scratch repos,
# but it runs a kit script that reads a repository it is pointed at — the guard is what proves it
# never read/wrote the frozen fixture instead.
kit_guard kit_guard_samples_unchanged

fail() { echo "FAIL: $1"; exit 1; }

[ -x "$FORGE" ] || fail "$FORGE missing or not executable"

WORK=$(kit_scratch)
mkdir -p "$WORK/bin"

# ------------------------------------------------------------------------------------- the stubs
#
# Both stubs record their invocation to $FORGE_STUB_LOG so a case can assert on the CLI contract
# (what forge.sh actually asked the forge) as well as on the normalised stdout. Recording is what
# keeps the seam at "does forge.sh call the forge correctly", not "does forge.sh call the function
# I renamed to look like the forge".

cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ -n "${FORGE_STUB_LOG:-}" ] && printf 'gh %s\n' "$*" >> "$FORGE_STUB_LOG"
# `--repo <slug>` is REQUIRED on every issue/pr subcommand: forge.sh never cd's, so a real gh
# would otherwise resolve the repository from the process's own working directory. Rejecting the
# invocation that lacks it is what keeps this stub honest about that contract.
# Real gh accepts `--repo` and its short form `-R` interchangeably, and the two callers here use
# different ones (forge.sh spells it out; guarded-pr-merge.sh has always passed -R). A stub that
# knew only one spelling would refuse a perfectly valid invocation and report it as a forge failure.
needs_repo() {
  case " $* " in *" --repo "*|*" -R "*) return 0 ;; esac
  echo "gh stub: '$1 $2' called without --repo/-R" >&2; exit 65
}
case "$1 $2" in
  "auth status")
    [ "${GH_AUTH_OK:-1}" = "1" ] || { echo "not logged in" >&2; exit 1; }
    echo "github.com: logged in"; exit 0 ;;
  "api user")
    [ "${GH_AUTH_OK:-1}" = "1" ] || { echo "HTTP 401" >&2; exit 1; }
    echo '{"login":"octocat"}'; exit 0 ;;
  "issue view")
    needs_repo "$@"
    [ -n "${GH_ISSUE_FIXTURE:-}" ] || { echo "GH_ISSUE_FIXTURE not set" >&2; exit 1; }
    cat "$GH_ISSUE_FIXTURE"; exit 0 ;;
  "issue list")
    needs_repo "$@"
    [ -n "${GH_ISSUES_FIXTURE:-}" ] || { echo "GH_ISSUES_FIXTURE not set" >&2; exit 1; }
    cat "$GH_ISSUES_FIXTURE"; exit 0 ;;
  "issue create")
    needs_repo "$@"
    echo "https://github.com/acme/widgets/issues/99"; exit 0 ;;
  "issue edit"|"issue reopen")
    needs_repo "$@"; exit 0 ;;
  "issue comment")
    needs_repo "$@"
    echo "https://github.com/acme/widgets/issues/47#issuecomment-5150"; exit 0 ;;
  "pr view")
    needs_repo "$@"
    # guarded-pr-merge.sh asks for a TSV readback (`--jq '[…] | @tsv'`); forge.sh's own reads ask
    # for the JSON document. Telling them apart by the presence of --jq is what lets one stub serve
    # both without either pretending to be the other.
    case " $* " in
      *" --jq "*)
        printf '%s\t%s\t%s\n' "${GH_VIEW_STATE:-MERGED}" "${GH_VIEW_MERGED_AT:-2026-09-08T00:00:00Z}" "${GH_VIEW_SHA:-cafef00d}"
        exit 0 ;;
    esac
    [ -n "${GH_PR_FIXTURE:-}" ] || { echo "GH_PR_FIXTURE not set" >&2; exit 1; }
    cat "$GH_PR_FIXTURE"; exit 0 ;;
  "pr merge")
    exit "${GH_MERGE_RC:-0}" ;;
  "pr create")
    needs_repo "$@"
    echo "https://github.com/acme/widgets/pull/281"; exit 0 ;;
  "pr ready")
    needs_repo "$@"; exit 0 ;;
  "pr comment")
    needs_repo "$@"
    echo "https://github.com/acme/widgets/pull/281#issuecomment-77"; exit 0 ;;
  "pr list")
    needs_repo "$@"
    [ -n "${GH_PRS_FIXTURE:-}" ] || { echo "GH_PRS_FIXTURE not set" >&2; exit 1; }
    cat "$GH_PRS_FIXTURE"; exit 0 ;;
  "pr diff")
    needs_repo "$@"
    printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n'; exit 0 ;;
esac
# `gh api <endpoint>` for everything that has no porcelain: the check-runs of a commit.
if [ "$1" = "api" ]; then
  case "$2" in
    */check-runs)
      [ -n "${GH_CHECKS_FIXTURE:-}" ] || { echo "GH_CHECKS_FIXTURE not set" >&2; exit 1; }
      cat "$GH_CHECKS_FIXTURE"; exit 0 ;;
  esac
fi
echo "gh stub: unexpected invocation: $*" >&2
exit 64
STUB

cat > "$WORK/bin/glab" <<'STUB'
#!/usr/bin/env bash
[ -n "${FORGE_STUB_LOG:-}" ] && printf 'glab %s\n' "$*" >> "$FORGE_STUB_LOG"
if [ "$1 $2" = "auth status" ]; then
  [ "${GLAB_AUTH_OK:-1}" = "1" ] || { echo "not logged in" >&2; exit 1; }
  echo "gitlab.example.com: logged in"; exit 0
fi
if [ "$1" = "api" ]; then
  endpoint="$2"
  method="GET"
  body=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "--method" ] && method="$a"
    [ "$prev" = "--input" ] && body="$a"
    prev="$a"
  done
  # A write must arrive as a JSON document on stdin (`--input -`), never as repeated key=value
  # flags: `gh -f` and `glab -f` do not agree on type coercion, and a body containing newlines
  # cannot survive either spelling. Draining stdin here is what proves forge.sh actually sent one.
  if [ "$method" != "GET" ]; then
    [ "$body" = "-" ] || { echo "glab stub: $method $endpoint without --input -" >&2; exit 65; }
    payload=$(cat)
    [ -n "${FORGE_STUB_LOG:-}" ] && printf 'glab-payload %s\n' "$(printf '%s' "$payload" | tr -d '\n')" >> "$FORGE_STUB_LOG"
  fi
  # Endpoint-shaped dispatch: `forge pr checks` on this arm is TWO round trips (the MR's pipelines,
  # then the latest pipeline's jobs), so one fixture variable cannot serve them both.
  case "$endpoint" in
    user)
      [ "${GLAB_AUTH_OK:-1}" = "1" ] || { echo "401 Unauthorized" >&2; exit 1; }
      echo '{"username":"tanuki"}'; exit 0 ;;
    */pipelines|*/pipelines\?*)
      [ -n "${GLAB_PIPELINES_FIXTURE:-}" ] || { echo "glab stub: no GLAB_PIPELINES_FIXTURE" >&2; exit 1; }
      cat "$GLAB_PIPELINES_FIXTURE"; exit 0 ;;
    */jobs|*/jobs\?*)
      [ -n "${GLAB_JOBS_FIXTURE:-}" ] || { echo "glab stub: no GLAB_JOBS_FIXTURE" >&2; exit 1; }
      cat "$GLAB_JOBS_FIXTURE"; exit 0 ;;
    */changes|*/changes\?*)
      [ -n "${GLAB_CHANGES_FIXTURE:-}" ] || { echo "glab stub: no GLAB_CHANGES_FIXTURE" >&2; exit 1; }
      cat "$GLAB_CHANGES_FIXTURE"; exit 0 ;;
  esac
  # Everything else is fixture-driven: the case points GLAB_FIXTURE at the payload the real REST
  # endpoint would return. An unset fixture is an error, not an empty answer (#294's lesson).
  [ -n "${GLAB_FIXTURE:-}" ] || { echo "glab stub: no GLAB_FIXTURE for $endpoint" >&2; exit 1; }
  cat "$GLAB_FIXTURE"; exit 0
fi
echo "glab stub: unexpected invocation: $*" >&2
exit 64
STUB

chmod +x "$WORK/bin/gh" "$WORK/bin/glab"
PATH="$WORK/bin:$PATH"
export PATH

# ------------------------------------------------------------------------------------- fixtures
#
# mkrepo <name> [origin-url] — a scratch git repo, optionally with an origin remote.
mkrepo() {
  local d
  d="$(kit_scratch)/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@test -c user.name=T commit -q --allow-empty -m init
  [ -n "${2:-}" ] && git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}

# mkprofile <repo> <tracker-line> — write a committed-shape profile carrying that Tracker line.
mkprofile() {
  mkdir -p "$1/.claude/skills"
  {
    printf '# Repo profile\n\n## Identity\n- **Repo:** acme/widgets\n\n## Tracker\n'
    printf '%s\n' "$2"
  } > "$1/.claude/skills/repo-profile.md"
}

# ============================================================== 1. kind, from the profile Tracker

# 1a. The committed-profile spelling (bold markdown), github.
repo=$(mkrepo gh-profile "https://github.com/acme/widgets.git")
mkprofile "$repo" '- **Tracker:** github (github.com) — the lifecycle skills drive GitHub semantics.'
out=$(bash "$FORGE" -C "$repo" kind) || fail "kind (github profile): non-zero exit"
[ "$out" = "github" ] || fail "kind (github profile): expected 'github', got '$out'"

# 1b. The committed-profile spelling, gitlab. The origin here is github.com ON PURPOSE: the
#     profile is the routing key, so a disagreeing remote must NOT win. If it did, a repo whose
#     origin still points at an old host would silently drive the wrong forge.
repo=$(mkrepo gl-profile "https://github.com/acme/widgets.git")
mkprofile "$repo" '- **Tracker:** gitlab (gitlab.example.com) — driven through glab.'
out=$(bash "$FORGE" -C "$repo" kind) || fail "kind (gitlab profile): non-zero exit"
[ "$out" = "gitlab" ] || fail "kind (gitlab profile): profile must beat the remote, got '$out'"

# 1c. The `detect` spelling (plain `tracker: …`, what repo-profile.sh emits) parses too. Two
#     spellings of one line exist in the tree — the template's bold form and detect's plain form —
#     so a parser that only knows one of them fails on half the profiles in the wild.
repo=$(mkrepo gl-plain "https://github.com/acme/widgets.git")
mkprofile "$repo" 'tracker: gitlab (gitlab.example.com)'
out=$(bash "$FORGE" -C "$repo" kind) || fail "kind (plain tracker spelling): non-zero exit"
[ "$out" = "gitlab" ] || fail "kind (plain tracker spelling): expected 'gitlab', got '$out'"

# 1d. A profile whose Tracker is still a TODO falls through to the remote rather than refusing —
#     "the probe never answered" is not "the answer is no".
repo=$(mkrepo todo-profile "https://github.com/acme/widgets.git")
mkprofile "$repo" '- **Tracker:** TODO: no origin remote — cannot name the tracker'
out=$(bash "$FORGE" -C "$repo" kind) || fail "kind (TODO tracker): non-zero exit"
[ "$out" = "github" ] || fail "kind (TODO tracker): expected fallback to 'github', got '$out'"

# ================================================================= 2. kind, from the origin host

# 2a. No profile at all, github.com origin.
repo=$(mkrepo no-profile-gh "git@github.com:acme/widgets.git")
out=$(bash "$FORGE" -C "$repo" kind) || fail "kind (no profile, github origin): non-zero exit"
[ "$out" = "github" ] || fail "kind (no profile, github origin): expected 'github', got '$out'"

# 2b. No profile, a gitlab.* host — recognised by name.
repo=$(mkrepo no-profile-gl "ssh://git@gitlab.example.com:2222/group/widgets.git")
out=$(bash "$FORGE" -C "$repo" kind) || fail "kind (no profile, gitlab host): non-zero exit"
[ "$out" = "gitlab" ] || fail "kind (no profile, gitlab host): expected 'gitlab', got '$out'"

# 2c. No profile, a self-hosted host whose NAME says nothing (`git.acme.io`). The positive signal
#     is that `glab` is authenticated against it — the same shape repo-profile.sh's Tracker probe
#     uses ($SLUG, i.e. `gh repo view` succeeding, rather than a literal string match).
repo=$(mkrepo no-profile-selfhosted "https://git.acme.io/group/widgets.git")
out=$(GLAB_AUTH_OK=1 GH_AUTH_OK=0 bash "$FORGE" -C "$repo" kind) \
  || fail "kind (self-hosted, glab authed): non-zero exit"
[ "$out" = "gitlab" ] || fail "kind (self-hosted, glab authed): expected 'gitlab', got '$out'"

# 2d. The same host with gh authenticated instead → github (a GitHub Enterprise host).
out=$(GLAB_AUTH_OK=0 GH_AUTH_OK=1 bash "$FORGE" -C "$repo" kind) \
  || fail "kind (self-hosted, gh authed): non-zero exit"
[ "$out" = "github" ] || fail "kind (self-hosted, gh authed): expected 'github', got '$out'"

# ==================================================================== 3. UNKNOWN_FORGE, exit 3

# 3a. No profile and no origin remote: nothing establishes an arm.
repo=$(mkrepo bare-repo)
rc=0; err=$(bash "$FORGE" -C "$repo" kind 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 3 ] || fail "kind (no profile, no origin): expected exit 3, got $rc"
case "$err" in *UNKNOWN_FORGE*) ;; *) fail "kind (no origin): stderr must name UNKNOWN_FORGE, got '$err'" ;; esac

# 3b. An origin whose host neither name nor auth can place. A guess here would route real writes at
#     the wrong forge, so the refusal is the feature.
repo=$(mkrepo unknown-host "https://git.acme.io/group/widgets.git")
rc=0; err=$(GLAB_AUTH_OK=0 GH_AUTH_OK=0 bash "$FORGE" -C "$repo" kind 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 3 ] || fail "kind (unplaceable host): expected exit 3, got $rc"
case "$err" in *UNKNOWN_FORGE*) ;; *) fail "kind (unplaceable host): stderr must name UNKNOWN_FORGE" ;; esac

# ============================================================================== 4. slug

# 4a. GitHub → owner/repo.
repo=$(mkrepo slug-gh "https://github.com/acme/widgets.git")
out=$(bash "$FORGE" -C "$repo" slug) || fail "slug (github): non-zero exit"
[ "$out" = "acme/widgets" ] || fail "slug (github): expected 'acme/widgets', got '$out'"

# 4b. GitLab with SUBGROUPS → the whole path, URL-encoded. A slug that assumes exactly two
#     segments is wrong on GitLab, and `projects/:id` needs the encoded form.
repo=$(mkrepo slug-gl "git@gitlab.example.com:group/sub/project.git")
out=$(bash "$FORGE" -C "$repo" slug) || fail "slug (gitlab subgroups): non-zero exit"
[ "$out" = "group%2Fsub%2Fproject" ] \
  || fail "slug (gitlab subgroups): expected 'group%2Fsub%2Fproject', got '$out'"

# 4c. An scp-like GitHub remote with no .git suffix still resolves.
repo=$(mkrepo slug-gh-scp "git@github.com:acme/widgets")
out=$(bash "$FORGE" -C "$repo" slug) || fail "slug (scp, no .git): non-zero exit"
[ "$out" = "acme/widgets" ] || fail "slug (scp, no .git): expected 'acme/widgets', got '$out'"

# ============================================================================== 5. auth

# 5a. GitHub arm → the login, via `gh api user`.
repo=$(mkrepo auth-gh "https://github.com/acme/widgets.git")
log="$WORK/auth-gh.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" bash "$FORGE" -C "$repo" auth) || fail "auth (github): non-zero exit"
[ "$out" = "octocat" ] || fail "auth (github): expected 'octocat', got '$out'"
grep -q 'gh api user' "$log" || fail "auth (github): forge did not call 'gh api user' — log: $(cat "$log")"

# 5b. GitLab arm → the username, via `glab api user`.
repo=$(mkrepo auth-gl "https://gitlab.example.com/group/widgets.git")
log="$WORK/auth-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" bash "$FORGE" -C "$repo" auth) || fail "auth (gitlab): non-zero exit"
[ "$out" = "tanuki" ] || fail "auth (gitlab): expected 'tanuki', got '$out'"
grep -q 'glab api user' "$log" || fail "auth (gitlab): forge did not call 'glab api user' — log: $(cat "$log")"

# 5c. A failed GitLab auth exits 1 and names the REMEDY for the right CLI and the right host.
#     A remedy naming `gh auth login` on a GitLab host is how a user loses an afternoon.
repo=$(mkrepo auth-gl-fail "https://gitlab.example.com/group/widgets.git")
rc=0; err=$(GLAB_AUTH_OK=0 bash "$FORGE" -C "$repo" auth 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] || fail "auth (gitlab, not logged in): expected exit 1, got $rc"
case "$err" in
  *"glab auth login"*"gitlab.example.com"*) ;;
  *) fail "auth (gitlab, not logged in): remedy must name 'glab auth login --hostname gitlab.example.com', got '$err'" ;;
esac

# 5d. The GitHub arm's remedy names gh and its host.
repo=$(mkrepo auth-gh-fail "https://github.com/acme/widgets.git")
rc=0; err=$(GH_AUTH_OK=0 bash "$FORGE" -C "$repo" auth 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 1 ] || fail "auth (github, not logged in): expected exit 1, got $rc"
case "$err" in
  *"gh auth login"*"github.com"*) ;;
  *) fail "auth (github, not logged in): remedy must name 'gh auth login -h github.com', got '$err'" ;;
esac

# ================================================================ 6. bad invocation → exit 2

repo=$(mkrepo bad-invocation "https://github.com/acme/widgets.git")
rc=0; bash "$FORGE" -C "$repo" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "no verb: expected exit 2, got $rc"

rc=0; bash "$FORGE" -C "$repo" nonsense >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown verb: expected exit 2, got $rc"

# A -C pointing at something that is not a repository is a bad invocation, not UNKNOWN_FORGE:
# no verdict was reached, and the two must not share an exit code.
rc=0; bash "$FORGE" -C "$WORK/definitely-not-a-repo" kind >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "-C outside a repository: expected exit 2, got $rc"

# ==================================================== 7. issue view — ONE shape from two forges
#
# The whole point of the dispatcher: the two forges disagree about almost every key of an issue
# (`number` vs `iid`, `OPEN` vs `opened`, `[{name}]` vs `[string]`, `url` vs `web_url`), and the
# skills must never see that. Both arms are driven from each forge's OWN native payload and both
# are compared against the SAME committed expectation — comparing the arms to each other instead
# would pass just as happily if both were wrong.

EXPECT="$KIT/tests/forge/fixtures/issue.expected.json"
[ -r "$EXPECT" ] || fail "missing fixture $EXPECT"

# gh issue view --json … — the porcelain shape, which is what the Spec's mapping table names.
cat > "$WORK/gh-issue.json" <<'JSON'
{
  "number": 47,
  "title": "Add CSV export",
  "state": "OPEN",
  "labels": [{"name": "enhancement"}, {"name": "effort: small"}],
  "url": "https://github.com/acme/widgets/issues/47",
  "updatedAt": "2026-09-08T10:00:00Z"
}
JSON

# GET /projects/:id/issues/:iid — the REST shape.
cat > "$WORK/gl-issue.json" <<'JSON'
{
  "iid": 47,
  "id": 90210,
  "title": "Add CSV export",
  "description": "body text",
  "state": "opened",
  "labels": ["enhancement", "effort: small"],
  "web_url": "https://gitlab.example.com/group/widgets/-/issues/47",
  "updated_at": "2026-09-08T10:00:00Z"
}
JSON

repo=$(mkrepo issue-gh "https://github.com/acme/widgets.git")
log="$WORK/issue-gh.log"; : > "$log"
gh_out=$(FORGE_STUB_LOG="$log" GH_ISSUE_FIXTURE="$WORK/gh-issue.json" \
  bash "$FORGE" -C "$repo" issue view 47 --fields number,title,state,labels) \
  || fail "issue view (github): non-zero exit"
# The CLI contract, not just the payload: a real `gh issue view` run from forge.sh's own working
# directory would resolve the wrong repository without --repo.
grep -q -- '--repo acme/widgets' "$log" \
  || fail "issue view (github): --repo not passed — log: $(cat "$log")"

repo=$(mkrepo issue-gl "https://gitlab.example.com/group/widgets.git")
log="$WORK/issue-gl.log"; : > "$log"
gl_out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-issue.json" \
  bash "$FORGE" -C "$repo" issue view 47 --fields number,title,state,labels) \
  || fail "issue view (gitlab): non-zero exit"
grep -q 'projects/group%2Fwidgets/issues/47' "$log" \
  || fail "issue view (gitlab): endpoint not projects/<encoded>/issues/47 — log: $(cat "$log")"

for arm in gh gl; do
  eval "got=\$${arm}_out"
  diff <(printf '%s\n' "$got" | jq -S .) <(jq -S . "$EXPECT") >/dev/null \
    || fail "issue view ($arm): does not match the shared expectation:
$(diff <(printf '%s\n' "$got" | jq -S .) <(jq -S . "$EXPECT") || true)"
done

# 7b. --fields is a PROJECTION: asking for less returns less, on both arms alike. Without this a
#     caller reading `.body` would work on one forge and silently read null on the other.
for spec in "gh:GH_ISSUE_FIXTURE=$WORK/gh-issue.json:issue-gh2:https://github.com/acme/widgets.git" \
            "gl:GLAB_FIXTURE=$WORK/gl-issue.json:issue-gl2:https://gitlab.example.com/group/widgets.git"; do
  arm=${spec%%:*}; rest=${spec#*:}
  envassign=${rest%%:*}; rest=${rest#*:}
  name=${rest%%:*}; url=${rest#*:}
  repo=$(mkrepo "$name" "$url")
  out=$(env "$envassign" bash "$FORGE" -C "$repo" issue view 47 --fields number,state) \
    || fail "issue view projection ($arm): non-zero exit"
  [ "$(printf '%s\n' "$out" | jq -S -c .)" = '{"number":47,"state":"open"}' ] \
    || fail "issue view projection ($arm): expected only number+state, got '$out'"
done

# ============================================================ 8. issue list — the same, as an array

cat > "$WORK/gh-issues.json" <<'JSON'
[
  {"number": 47, "title": "Add CSV export", "state": "OPEN",
   "labels": [{"name": "enhancement"}, {"name": "effort: small"}],
   "url": "https://github.com/acme/widgets/issues/47", "updatedAt": "2026-09-08T10:00:00Z"}
]
JSON
cat > "$WORK/gl-issues.json" <<'JSON'
[
  {"iid": 47, "id": 90210, "title": "Add CSV export", "description": "body text",
   "state": "opened", "labels": ["enhancement", "effort: small"],
   "web_url": "https://gitlab.example.com/group/widgets/-/issues/47",
   "updated_at": "2026-09-08T10:00:00Z"}
]
JSON

repo=$(mkrepo list-gh "https://github.com/acme/widgets.git")
gh_list=$(GH_ISSUES_FIXTURE="$WORK/gh-issues.json" \
  bash "$FORGE" -C "$repo" issue list --state open --fields number,title,state,labels) \
  || fail "issue list (github): non-zero exit"
repo=$(mkrepo list-gl "https://gitlab.example.com/group/widgets.git")
log="$WORK/list-gl.log"; : > "$log"
gl_list=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-issues.json" \
  bash "$FORGE" -C "$repo" issue list --state open --fields number,title,state,labels) \
  || fail "issue list (gitlab): non-zero exit"

# `open` is the kit's word; GitLab's REST vocabulary spells it `opened`. The translation belongs to
# forge.sh, so a skill never has to know which forge it is filtering on.
grep -q 'state=opened' "$log" \
  || fail "issue list (gitlab): --state open must become state=opened — log: $(cat "$log")"

for arm in gh gl; do
  eval "got=\$${arm}_list"
  [ "$(printf '%s\n' "$got" | jq 'type')" = '"array"' ] || fail "issue list ($arm): not an array"
  diff <(printf '%s\n' "$got" | jq -S '.[0]') <(jq -S . "$EXPECT") >/dev/null \
    || fail "issue list ($arm): element 0 does not match the shared expectation"
done

# An empty result is an empty ARRAY and a zero exit — distinguishable from a failure, which is
# non-zero. Conflating the two is how "no unresolved threads" gets read out of a broken query.
echo '[]' > "$WORK/empty.json"
repo=$(mkrepo list-empty "https://gitlab.example.com/group/widgets.git")
out=$(GLAB_FIXTURE="$WORK/empty.json" bash "$FORGE" -C "$repo" issue list --fields number) \
  || fail "issue list (empty): must exit 0"
[ "$out" = "[]" ] || fail "issue list (empty): expected '[]', got '$out'"

repo=$(mkrepo list-broken "https://gitlab.example.com/group/widgets.git")
rc=0; bash "$FORGE" -C "$repo" issue list --fields number >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "issue list (forge query failed): must exit non-zero, not print []"

# ==================================================== 9. issue create / edit / comment / reopen

repo=$(mkrepo create-gh "https://github.com/acme/widgets.git")
printf 'a body\nwith two lines\n' > "$WORK/body.md"
out=$(bash "$FORGE" -C "$repo" issue create --title "Add CSV export" --body-file "$WORK/body.md" \
  --label enhancement --label "effort: small") || fail "issue create (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .number)" = "99" ] \
  || fail "issue create (github): expected number 99, got '$out'"
[ "$(printf '%s\n' "$out" | jq -r .url)" = "https://github.com/acme/widgets/issues/99" ] \
  || fail "issue create (github): url not carried through, got '$out'"

cat > "$WORK/gl-created.json" <<'JSON'
{"iid": 99, "web_url": "https://gitlab.example.com/group/widgets/-/issues/99"}
JSON
repo=$(mkrepo create-gl "https://gitlab.example.com/group/widgets.git")
log="$WORK/create-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-created.json" \
  bash "$FORGE" -C "$repo" issue create --title "Add CSV export" --body-file "$WORK/body.md" \
  --label enhancement --label "effort: small") || fail "issue create (gitlab): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .number)" = "99" ] \
  || fail "issue create (gitlab): expected number 99, got '$out'"
grep -q 'glab-payload' "$log" || fail "issue create (gitlab): no JSON payload was sent — log: $(cat "$log")"
# The multi-line body must survive as ONE JSON string. Repeated -f key=value flags cannot carry a
# newline on either CLI, which is why every write goes in as a document on stdin.
payload=$(grep '^glab-payload ' "$log" | sed 's/^glab-payload //')
# Compared as ESCAPED JSON strings, never through `jq -r`. On a Windows host jq writes stdout in
# text mode, so `jq -r` turns every decoded \n back into \r\n and two identical bodies compare
# unequal — the profile's "text I/O is where the boundary bites" gotcha, one layer down. Both sides
# here stay single-line JSON, where a \n is two characters and no translation can reach it.
[ "$(printf '%s' "$payload" | jq -c .description)" = "$(jq -Rs . < "$WORK/body.md")" ] \
  || fail "issue create (gitlab): the body did not survive the payload, got '$payload'"
[ "$(printf '%s' "$payload" | jq -r .labels)" = "enhancement,effort: small" ] \
  || fail "issue create (gitlab): labels must be a comma list, got '$payload'"

repo=$(mkrepo comment-gh "https://github.com/acme/widgets.git")
out=$(bash "$FORGE" -C "$repo" issue comment 47 --body-file "$WORK/body.md") \
  || fail "issue comment (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .url)" = "https://github.com/acme/widgets/issues/47#issuecomment-5150" ] \
  || fail "issue comment (github): url not carried, got '$out'"

repo=$(mkrepo reopen-gl "https://gitlab.example.com/group/widgets.git")
log="$WORK/reopen-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-issue.json" \
  bash "$FORGE" -C "$repo" issue reopen 47) || fail "issue reopen (gitlab): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .state)" = "open" ] \
  || fail "issue reopen (gitlab): expected state open, got '$out'"
grep -q 'state_event' "$log" \
  || fail "issue reopen (gitlab): must PUT state_event=reopen — log: $(cat "$log")"

# ================================================================ 10. issue templates, per forge

repo=$(mkrepo tpl-gh "https://github.com/acme/widgets.git")
mkdir -p "$repo/.github/ISSUE_TEMPLATE"
: > "$repo/.github/ISSUE_TEMPLATE/feature_request.yml"
: > "$repo/.github/ISSUE_TEMPLATE/bug_report.yml"
out=$(bash "$FORGE" -C "$repo" issue templates) || fail "issue templates (github): non-zero exit"
printf '%s\n' "$out" | grep -q 'ISSUE_TEMPLATE/bug_report.yml' \
  || fail "issue templates (github): did not list the forms, got '$out'"

repo=$(mkrepo tpl-gl "https://gitlab.example.com/group/widgets.git")
mkdir -p "$repo/.gitlab/issue_templates"
: > "$repo/.gitlab/issue_templates/Feature.md"
out=$(bash "$FORGE" -C "$repo" issue templates) || fail "issue templates (gitlab): non-zero exit"
printf '%s\n' "$out" | grep -q 'issue_templates/Feature.md' \
  || fail "issue templates (gitlab): must read .gitlab/issue_templates/, got '$out'"

# A repo with no templates is a zero-exit empty answer, not an error: create-issue's Step 4 emits
# nothing in that case rather than refusing to file.
repo=$(mkrepo tpl-none "https://github.com/acme/widgets.git")
out=$(bash "$FORGE" -C "$repo" issue templates) || fail "issue templates (none): must exit 0"
[ -z "$out" ] || fail "issue templates (none): expected no output, got '$out'"

# ============================================== 11. pr view — the three real semantic divergences
#
# This is the case the whole dispatcher exists for. A merge request is where the two forges stop
# agreeing about facts, not just spellings:
#
#   draft         GitHub has an `isDraft` boolean; GitLab has a `Draft: ` TITLE PREFIX and nothing
#                 else. So the normalised `title` must come back WITHOUT the prefix on both arms —
#                 otherwise every skill that reads a title has to know which forge wrote it.
#   blockers      GitHub's `mergeStateStatus` is one coarse enum; GitLab's `detailed_merge_status`
#                 is a finer one. Neither is a subset of the other, so the mapping is a stated
#                 policy (skills/_shared/forge.md) rather than a lookup either side agrees with.
#   approval      GitLab approval rules are a paid feature; the free API cannot express
#                 "changes requested" at all.

PR_EXPECT="$KIT/tests/forge/fixtures/pr.expected.json"
[ -r "$PR_EXPECT" ] || fail "missing fixture $PR_EXPECT"

cat > "$WORK/gh-pr.json" <<'JSON'
{
  "number": 281, "title": "add X", "body": "pr body", "state": "OPEN", "isDraft": true,
  "headRefName": "feat/1-x", "baseRefName": "main", "headRefOid": "abc1234",
  "url": "https://github.com/acme/widgets/pull/281",
  "mergeable": "MERGEABLE", "mergeStateStatus": "BLOCKED", "reviewDecision": "REVIEW_REQUIRED"
}
JSON

cat > "$WORK/gl-pr.json" <<'JSON'
{
  "iid": 281, "title": "Draft: add X", "description": "pr body", "state": "opened",
  "source_branch": "feat/1-x", "target_branch": "main", "sha": "abc1234",
  "web_url": "https://gitlab.example.com/group/widgets/-/merge_requests/281",
  "has_conflicts": false, "detailed_merge_status": "discussions_not_resolved"
}
JSON

FIELDS_PR=number,title,state,isDraft,headRefName,baseRefName,headSha

repo=$(mkrepo pr-gh "https://github.com/acme/widgets.git")
gh_pr=$(GH_PR_FIXTURE="$WORK/gh-pr.json" bash "$FORGE" -C "$repo" pr view 281 --fields "$FIELDS_PR") \
  || fail "pr view (github): non-zero exit"
repo_gl=$(mkrepo pr-gl "https://gitlab.example.com/group/widgets.git")
log="$WORK/pr-gl.log"; : > "$log"
gl_pr=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-pr.json" \
  bash "$FORGE" -C "$repo_gl" pr view 281 --fields "$FIELDS_PR") \
  || fail "pr view (gitlab): non-zero exit"
grep -q 'projects/group%2Fwidgets/merge_requests/281' "$log" \
  || fail "pr view (gitlab): wrong endpoint — log: $(cat "$log")"

for arm in gh gl; do
  eval "got=\$${arm}_pr"
  diff <(printf '%s\n' "$got" | jq -S .) <(jq -S . "$PR_EXPECT") >/dev/null \
    || fail "pr view ($arm): does not match the shared expectation:
$(diff <(printf '%s\n' "$got" | jq -S .) <(jq -S . "$PR_EXPECT") || true)"
done

# The GitLab title arrives as `Draft: add X` and comes back as `add X`. Stated separately from the
# diff above because it is the single most load-bearing normalisation in this file: `forge pr ready`
# works by REMOVING that prefix, so a title that still carried it would be re-prefixed on the next
# edit and the MR would silently go back to draft.
[ "$(printf '%s\n' "$gl_pr" | jq -r .title)" = "add X" ] \
  || fail "pr view (gitlab): the Draft: prefix must not reach the caller"

# mergeBlockers: the finer GitLab status is preserved, the coarser GitHub one is mapped, and BOTH
# report the draft. A caller gating a merge reads this array and never the forge's own enum.
gh_blk=$(GH_PR_FIXTURE="$WORK/gh-pr.json" bash "$FORGE" -C "$repo" pr view 281 --fields mergeBlockers)
gl_blk=$(GLAB_FIXTURE="$WORK/gl-pr.json" bash "$FORGE" -C "$repo_gl" pr view 281 --fields mergeBlockers)
for arm in gh gl; do
  eval "got=\$${arm}_blk"
  printf '%s\n' "$got" | jq -e '.mergeBlockers | index("draft")' >/dev/null \
    || fail "pr view ($arm): mergeBlockers must contain 'draft', got '$got'"
done
printf '%s\n' "$gl_blk" | jq -e '.mergeBlockers | index("threads_unresolved")' >/dev/null \
  || fail "pr view (gitlab): discussions_not_resolved must map to threads_unresolved, got '$gl_blk'"
printf '%s\n' "$gh_blk" | jq -e '.mergeBlockers | index("not_approved")' >/dev/null \
  || fail "pr view (github): mergeStateStatus BLOCKED must map to not_approved, got '$gh_blk'"

# An UNKNOWN detailed_merge_status is carried through verbatim rather than dropped. Silently
# discarding it would make a blocked MR look mergeable — the failure direction that costs the most.
cat > "$WORK/gl-pr-odd.json" <<'JSON'
{"iid": 281, "title": "add X", "state": "opened", "source_branch": "b", "target_branch": "main",
 "sha": "abc1234", "web_url": "https://x/y", "has_conflicts": false,
 "detailed_merge_status": "some_future_gitlab_status"}
JSON
out=$(GLAB_FIXTURE="$WORK/gl-pr-odd.json" bash "$FORGE" -C "$repo_gl" pr view 281 --fields mergeBlockers)
printf '%s\n' "$out" | jq -e '.mergeBlockers | index("some_future_gitlab_status")' >/dev/null \
  || fail "pr view (gitlab): an unmapped status must be carried through, got '$out'"

# A clean MR blocks on nothing, on both arms — the empty array, not null.
cat > "$WORK/gl-pr-clean.json" <<'JSON'
{"iid": 281, "title": "add X", "state": "opened", "source_branch": "b", "target_branch": "main",
 "sha": "abc1234", "web_url": "https://x/y", "has_conflicts": false,
 "detailed_merge_status": "mergeable"}
JSON
out=$(GLAB_FIXTURE="$WORK/gl-pr-clean.json" bash "$FORGE" -C "$repo_gl" pr view 281 --fields mergeBlockers,mergeable)
[ "$(printf '%s\n' "$out" | jq -c '.mergeBlockers')" = "[]" ] \
  || fail "pr view (gitlab, clean): expected [], got '$out'"
[ "$(printf '%s\n' "$out" | jq -r '.mergeable')" = "clean" ] \
  || fail "pr view (gitlab, clean): expected mergeable=clean, got '$out'"

# ================================================================= 12. pr checks — one shape

CHECKS_EXPECT="$KIT/tests/forge/fixtures/checks.expected.json"
[ -r "$CHECKS_EXPECT" ] || fail "missing fixture $CHECKS_EXPECT"

cat > "$WORK/gh-checks.json" <<'JSON'
{"check_runs": [
  {"name": "kit", "status": "completed", "conclusion": "success"},
  {"name": "title-gate", "status": "in_progress", "conclusion": null}
]}
JSON
cat > "$WORK/gl-pipelines.json" <<'JSON'
[{"id": 900, "sha": "abc1234", "status": "running"}]
JSON
cat > "$WORK/gl-jobs.json" <<'JSON'
[{"name": "kit", "status": "success"}, {"name": "title-gate", "status": "running"}]
JSON

repo=$(mkrepo checks-gh "https://github.com/acme/widgets.git")
gh_checks=$(GH_PR_FIXTURE="$WORK/gh-pr.json" GH_CHECKS_FIXTURE="$WORK/gh-checks.json" \
  bash "$FORGE" -C "$repo" pr checks 281) || fail "pr checks (github): non-zero exit"
log="$WORK/checks-gl.log"; : > "$log"
gl_checks=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-pr.json" \
  GLAB_PIPELINES_FIXTURE="$WORK/gl-pipelines.json" GLAB_JOBS_FIXTURE="$WORK/gl-jobs.json" \
  bash "$FORGE" -C "$repo_gl" pr checks 281) || fail "pr checks (gitlab): non-zero exit"

for arm in gh gl; do
  eval "got=\$${arm}_checks"
  diff <(printf '%s\n' "$got" | jq -S .) <(jq -S . "$CHECKS_EXPECT") >/dev/null \
    || fail "pr checks ($arm): does not match the shared expectation:
$(diff <(printf '%s\n' "$got" | jq -S .) <(jq -S . "$CHECKS_EXPECT") || true)"
done
# GitLab needs two round trips; assert BOTH happened rather than trusting the payload alone.
grep -q 'merge_requests/281/pipelines' "$log" || fail "pr checks (gitlab): pipelines never queried"
grep -q 'pipelines/900/jobs' "$log" || fail "pr checks (gitlab): the latest pipeline's jobs never queried"

# ======================================================================= 13. pr list and pr diff

cat > "$WORK/gh-prs.json" <<'JSON'
[{"number": 281, "title": "add X", "body": "b", "state": "OPEN", "isDraft": true,
  "headRefName": "feat/1-x", "baseRefName": "main", "headRefOid": "abc1234",
  "url": "https://github.com/acme/widgets/pull/281", "mergeable": "MERGEABLE",
  "mergeStateStatus": "BLOCKED", "reviewDecision": "REVIEW_REQUIRED"}]
JSON
repo=$(mkrepo prlist-gh "https://github.com/acme/widgets.git")
out=$(GH_PRS_FIXTURE="$WORK/gh-prs.json" \
  bash "$FORGE" -C "$repo" pr list --head feat/1-x --fields number,title) \
  || fail "pr list (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -c '.[0]')" = '{"number":281,"title":"add X"}' ] \
  || fail "pr list (github): got '$out'"

cat > "$WORK/gl-prs.json" <<'JSON'
[{"iid": 281, "title": "Draft: add X", "description": "b", "state": "opened",
  "source_branch": "feat/1-x", "target_branch": "main", "sha": "abc1234",
  "web_url": "https://x/y", "has_conflicts": false, "detailed_merge_status": "mergeable"}]
JSON
log="$WORK/prlist-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-prs.json" \
  bash "$FORGE" -C "$repo_gl" pr list --head feat/1-x --fields number,title) \
  || fail "pr list (gitlab): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -c '.[0]')" = '{"number":281,"title":"add X"}' ] \
  || fail "pr list (gitlab): got '$out'"
grep -q 'source_branch=feat/1-x' "$log" \
  || fail "pr list (gitlab): --head must become source_branch — log: $(cat "$log")"

cat > "$WORK/gl-changes.json" <<'JSON'
{"changes": [{"old_path": "a.txt", "new_path": "a.txt", "diff": "@@ -1 +1 @@\n-old\n+new\n"}]}
JSON
out=$(GLAB_CHANGES_FIXTURE="$WORK/gl-changes.json" bash "$FORGE" -C "$repo_gl" pr diff 281) \
  || fail "pr diff (gitlab): non-zero exit"
# GitLab's REST `changes[].diff` starts at the first hunk, with no `diff --git`/`---`/`+++`
# preamble. Every consumer of a diff expects those, so forge.sh synthesises them from old_path and
# new_path rather than handing back a fragment that looks like a diff and is not one.
printf '%s\n' "$out" | grep -q '^diff --git a/a.txt b/a.txt' \
  || fail "pr diff (gitlab): missing the synthesised git header, got '$out'"
printf '%s\n' "$out" | grep -q '^+new' || fail "pr diff (gitlab): the hunk was lost, got '$out'"

# =========================================== 14. pr create / ready — the Draft: prefix, both ways
#
# The asymmetry that has to be hidden: opening a draft is a FLAG on GitHub and a TITLE PREFIX on
# GitLab, and flipping to ready is a state transition on one and a title EDIT on the other. A
# caller that had to know which would be a caller that has to know the forge.

repo=$(mkrepo prcreate-gh "https://github.com/acme/widgets.git")
printf 'pr body\n' > "$WORK/prbody.md"
log="$WORK/prcreate-gh.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" bash "$FORGE" -C "$repo" pr create --title "add X" \
  --body-file "$WORK/prbody.md" --base main --head feat/1-x --draft) \
  || fail "pr create (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .number)" = "281" ] || fail "pr create (github): got '$out'"
grep -q -- '--draft' "$log" || fail "pr create (github): --draft not passed — log: $(cat "$log")"

cat > "$WORK/gl-created-mr.json" <<'JSON'
{"iid": 281, "web_url": "https://gitlab.example.com/group/widgets/-/merge_requests/281"}
JSON
log="$WORK/prcreate-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-created-mr.json" \
  bash "$FORGE" -C "$repo_gl" pr create --title "add X" --body-file "$WORK/prbody.md" \
  --base main --head feat/1-x --draft) || fail "pr create (gitlab): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .number)" = "281" ] || fail "pr create (gitlab): got '$out'"
payload=$(grep '^glab-payload ' "$log" | sed 's/^glab-payload //')
[ "$(printf '%s' "$payload" | jq -r .title)" = "Draft: add X" ] \
  || fail "pr create (gitlab, --draft): title must carry the Draft: prefix, got '$payload'"
[ "$(printf '%s' "$payload" | jq -r .source_branch)" = "feat/1-x" ] \
  || fail "pr create (gitlab): --head must become source_branch, got '$payload'"
[ "$(printf '%s' "$payload" | jq -r .target_branch)" = "main" ] \
  || fail "pr create (gitlab): --base must become target_branch, got '$payload'"

# Without --draft the prefix must NOT appear — otherwise every MR this kit opens would be a draft.
log="$WORK/prcreate-gl2.log"; : > "$log"
FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-created-mr.json" \
  bash "$FORGE" -C "$repo_gl" pr create --title "add X" --body-file "$WORK/prbody.md" \
  --base main --head feat/1-x >/dev/null || fail "pr create (gitlab, no draft): non-zero exit"
payload=$(grep '^glab-payload ' "$log" | sed 's/^glab-payload //')
[ "$(printf '%s' "$payload" | jq -r .title)" = "add X" ] \
  || fail "pr create (gitlab, no --draft): title must be unprefixed, got '$payload'"

# ready: GitHub transitions state; GitLab edits the title. The GitLab arm must READ the current
# title first — it can only strip a prefix it has seen.
repo=$(mkrepo prready-gh "https://github.com/acme/widgets.git")
log="$WORK/prready-gh.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" bash "$FORGE" -C "$repo" pr ready 281) \
  || fail "pr ready (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .isDraft)" = "false" ] || fail "pr ready (github): got '$out'"
grep -q 'gh pr ready 281' "$log" || fail "pr ready (github): gh pr ready never called — log: $(cat "$log")"

log="$WORK/prready-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-pr.json" \
  bash "$FORGE" -C "$repo_gl" pr ready 281) || fail "pr ready (gitlab): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .isDraft)" = "false" ] || fail "pr ready (gitlab): got '$out'"
payload=$(grep '^glab-payload ' "$log" | sed 's/^glab-payload //')
[ "$(printf '%s' "$payload" | jq -r .title)" = "add X" ] \
  || fail "pr ready (gitlab): the PUT must carry the title WITHOUT 'Draft: ', got '$payload'"

# ================================================ 15. pr merge — through the guard, on both arms
#
# The guard convention (README, "Hardening a destructive operation"): a destructive operation is
# never the raw command. Adding a second forge must not become a way around that, so BOTH arms go
# through skills/merge-pr/scripts/guarded-pr-merge.sh and neither calls the forge directly. What
# the guard does per arm is its own suite's business (tests/guarded-pr-merge/test.sh); what this
# case pins is that forge.sh reaches it and honours its verdict.

repo=$(mkrepo prmerge-gh "https://github.com/acme/widgets.git")
log="$WORK/prmerge-gh.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GH_MERGE_RC=0 GH_VIEW_STATE=MERGED GH_VIEW_SHA=cafef00d \
  GUARDED_PR_MERGE_READBACK_SLEEP=0 \
  bash "$FORGE" -C "$repo" pr merge 281 --squash --subject "feat(x): y (#1) (#2)") \
  || fail "pr merge (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .merged)" = "true" ] || fail "pr merge (github): got '$out'"
grep -q 'gh pr merge 281' "$log" \
  || fail "pr merge (github): the guard never reached gh pr merge — log: $(cat "$log")"

# A verdict that is not MERGED is a non-zero exit, never a cheerful {"merged":true}. QUEUED and
# REJECTED both mean "not landed", and a caller that read them as success would tear down a branch
# whose work is still open.
repo=$(mkrepo prmerge-rej "https://github.com/acme/widgets.git")
rc=0; out=$(GH_MERGE_RC=1 GH_VIEW_STATE=OPEN GUARDED_PR_MERGE_READBACK_SLEEP=0 \
  bash "$FORGE" -C "$repo" pr merge 281 --squash --subject "s" 2>/dev/null) || rc=$?
[ "$rc" -ne 0 ] || fail "pr merge (github, REJECTED): must exit non-zero, got '$out'"

# ============================================================================ 16. pr comment

repo=$(mkrepo prcomment-gh "https://github.com/acme/widgets.git")
out=$(bash "$FORGE" -C "$repo" pr comment 281 --body-file "$WORK/prbody.md") \
  || fail "pr comment (github): non-zero exit"
[ "$(printf '%s\n' "$out" | jq -r .url)" = "https://github.com/acme/widgets/pull/281#issuecomment-77" ] \
  || fail "pr comment (github): got '$out'"

cat > "$WORK/gl-note.json" <<'JSON'
{"id": 4242}
JSON
log="$WORK/prcomment-gl.log"; : > "$log"
out=$(FORGE_STUB_LOG="$log" GLAB_FIXTURE="$WORK/gl-note.json" \
  bash "$FORGE" -C "$repo_gl" pr comment 281 --body-file "$WORK/prbody.md") \
  || fail "pr comment (gitlab): non-zero exit"
printf '%s\n' "$out" | jq -e '.url | test("merge_requests/281#note_4242")' >/dev/null \
  || fail "pr comment (gitlab): expected an anchored note URL, got '$out'"
grep -q 'merge_requests/281/notes' "$log" \
  || fail "pr comment (gitlab): wrong endpoint — log: $(cat "$log")"

echo "OK: forge.sh — arm resolution, kind, slug, auth, issue verbs, merge-request reads and writes"
