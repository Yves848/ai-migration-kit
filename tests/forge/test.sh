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
case "$1 $2" in
  "auth status")
    [ "${GH_AUTH_OK:-1}" = "1" ] || { echo "not logged in" >&2; exit 1; }
    echo "github.com: logged in"; exit 0 ;;
  "api user")
    [ "${GH_AUTH_OK:-1}" = "1" ] || { echo "HTTP 401" >&2; exit 1; }
    echo '{"login":"octocat"}'; exit 0 ;;
esac
echo "gh stub: unexpected invocation: $*" >&2
exit 64
STUB

cat > "$WORK/bin/glab" <<'STUB'
#!/usr/bin/env bash
[ -n "${FORGE_STUB_LOG:-}" ] && printf 'glab %s\n' "$*" >> "$FORGE_STUB_LOG"
case "$1 $2" in
  "auth status")
    [ "${GLAB_AUTH_OK:-1}" = "1" ] || { echo "not logged in" >&2; exit 1; }
    echo "gitlab.example.com: logged in"; exit 0 ;;
  "api user")
    [ "${GLAB_AUTH_OK:-1}" = "1" ] || { echo "401 Unauthorized" >&2; exit 1; }
    echo '{"username":"tanuki"}'; exit 0 ;;
esac
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

echo "OK: forge.sh — arm resolution, kind, slug, auth"
