#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL, a GitLab merge request URL, and a Gitea pull
# request URL are all accepted, including one on a self-hosted GitLab or Gitea
# instance.
# A GitHub pull request the forge reports as a draft is refused, naming the draft
# state and recording and arming nothing: a draft cannot be merged, so a poll armed on it
# would wait for an event that cannot occur while nobody is asked to act.
# Mark the pull request ready for review, then arm again; a lane that keeps a
# draft on purpose declares a wait instead of reporting done. An unreadable
# draft state does not refuse, matching how the head read below is optional.
# bin/fm-pr-merge.sh records through this script with FM_PR_CHECK_MERGE=1 and
# skips this refusal, because its own merge-time draft refusal is authoritative.
#
# This script is the only writer of a task's PR binding: pr=, pr_head=, and the
# integrity record bin/fm-pr-binding-lib.sh owns, which also keeps the head's
# tree when the worktree has it. A binding is what merge authority applies to,
# so it changes only here and never by hand.
# Re-recording the same PR at a moved head is allowed and prints a notice that
# the changed PR has to be presented to the captain again, with its diff stat
# (bin/fm-review-diff.sh <id> --stat), before any merge.
# Replacing a bound PR with a different one is refused unless the bound PR's
# merge is proven, or --rebind "<reason>" is passed; --rebind records that
# reason and is attended-only, refused while the away-posture record exists,
# because a different PR needs the captain's fresh approval. An unreadable
# binding record is replaced only under --rebind as well.
# At merge time (FM_PR_CHECK_MERGE=1) an existing binding for the same PR is
# kept exactly as recorded, never refreshed to the live head, so the merge
# stays bound to the content that was presented; with no binding yet, the
# merge-time record binds the head the forge reports now. A merge-time record
# never rebinds.
# Usage: fm-pr-check.sh <task-id> <pr-url> [--rebind <reason>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-pr-binding-lib.sh
. "$SCRIPT_DIR/fm-pr-binding-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

REBIND_REASON=
case "$#" in
  2) ;;
  4)
    if [ "$3" != --rebind ] || [ -z "$(fm_pr_binding_clean_reason "$4" | tr -d ' ')" ]; then
      echo "error: invalid PR check request; --rebind requires a non-empty reason" >&2
      exit 2
    fi
    REBIND_REASON=$(fm_pr_binding_clean_reason "$4")
    ;;
  *)
    echo "error: invalid PR check request" >&2
    exit 2
    ;;
esac
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# The binding this record would replace, from the integrity record when there
# is one and from a legacy pr= line otherwise. The header owns when a different
# PR may replace it.
BINDING_READABLE=1
fm_pr_binding_read "$STATE" "$ID" || BINDING_READABLE=0
PRIOR_BINDING_PRESENT=$FM_PR_BINDING_PRESENT
PRIOR_URL=$FM_PR_BINDING_URL
PRIOR_HEAD=$FM_PR_BINDING_HEAD
PRIOR_TREE=$FM_PR_BINDING_TREE
if [ "$BINDING_READABLE" -eq 1 ] && [ "$PRIOR_BINDING_PRESENT" -eq 0 ]; then
  PRIOR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
  PRIOR_HEAD=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
fi
BINDING_REASON=ready
[ "${FM_PR_CHECK_MERGE:-}" != 1 ] || BINDING_REASON=merge
binding_prior_merged() {
  ( fm_pr_url_parse "$PRIOR_URL" \
    && fm_pr_poll_merge_already_notified "$STATE" "$ID" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" )
}
if [ "$BINDING_READABLE" -eq 0 ] || { [ -n "$PRIOR_URL" ] && [ "$PRIOR_URL" != "$URL" ] && ! binding_prior_merged; }; then
  if [ "$BINDING_READABLE" -eq 0 ]; then
    PRIOR_DESC="an unreadable binding record"
  else
    PRIOR_DESC=$PRIOR_URL
  fi
  if [ "${FM_PR_CHECK_MERGE:-}" = 1 ]; then
    echo "error: task $ID is bound to $PRIOR_DESC, not $URL; a merge never rebinds a task" >&2
    exit 1
  fi
  if [ -z "$REBIND_REASON" ]; then
    echo "error: task $ID is bound to $PRIOR_DESC, which has not merged; binding it to $URL changes the content the captain approves - present $URL and its diff stat to the captain, then pass --rebind \"<reason>\"" >&2
    exit 1
  fi
  if fm_afk_contract_present "$STATE"; then
    echo "error: --rebind is attended-only; while the away-posture record exists a task is never bound to a different PR" >&2
    exit 2
  fi
  BINDING_REASON="rebind from $PRIOR_DESC: $REBIND_REASON"
elif [ -n "$PRIOR_URL" ] && [ "$PRIOR_URL" != "$URL" ]; then
  BINDING_REASON="next PR after $PRIOR_URL merged"
elif [ -n "$REBIND_REASON" ]; then
  echo "error: --rebind applies only when replacing a different, unmerged PR binding" >&2
  exit 2
elif [ "$PRIOR_BINDING_PRESENT" -eq 1 ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ]; then
  BINDING_REASON=re-recorded
fi
# A merge-time record keeps an existing binding for the same PR exactly as it
# was recorded and presented.
# A Gitea binding records no head when the PR is registered (see below), so its
# first merge-time record binds the head the forge reports then, and later
# merge attempts are held to that head.
KEEP_BINDING=0
if [ "${FM_PR_CHECK_MERGE:-}" = 1 ] && [ "$PRIOR_BINDING_PRESENT" -eq 1 ] && [ "$PRIOR_URL" = "$URL" ]; then
  if [ "$PROVIDER" = gitea ] && [ -z "$PRIOR_HEAD" ]; then
    BINDING_REASON="merge-time head for $URL"
  else
    KEEP_BINDING=1
  fi
fi

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Gitea needs the same refusal for tea, plus one more: tea picks the instance
# from a login name in its own config rather than from the URL, so a host with
# no configured login, or with more than one, leaves the poll unable to address
# this pull request at all. Both are read from local configuration only. The
# instance itself is deliberately not contacted here, because a self-hosted
# Gitea is routinely off the network when its pull request is opened and
# refusing to arm then would lose the watch for a reachability dip.
if [ "$PROVIDER" = gitea ]; then
  if ! command -v tea >/dev/null 2>&1; then
    echo "error: watching a Gitea pull request requires tea on PATH" >&2
    exit 1
  fi
  GITEA_LOGIN=$(fm_pr_gitea_login "$HOST") || GITEA_LOGIN=
  if [ -z "$GITEA_LOGIN" ]; then
    echo "error: watching a Gitea pull request requires exactly one tea login for https://$HOST" >&2
    exit 1
  fi
fi

# The draft state is read before anything is recorded or armed. Only a positive
# draft reading refuses, because an unreadable one must not block arming.
if [ "$PROVIDER" = github ] && [ "${FM_PR_CHECK_MERGE:-}" != 1 ] && command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  DRAFT_JSON=$(gh pr view "$URL" --json isDraft 2>/dev/null || true)
  if [ "$(fm_pr_json_draft_state "$DRAFT_JSON")" = true ]; then
    echo "error: $URL is a draft pull request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate" >&2
    exit 1
  fi
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it without changing
# what arming costs. gh exposes the head commit as a selectable field; plain
# glab exposes it only inside its JSON output, which would need a JSON processor
# firstmate does not require, so a GitLab task records no pr_head. tea does
# expose it, but only over the network, which would make arming a Gitea watch
# wait on a self-hosted instance that is routinely unreachable, so a Gitea task
# records none either at registration; a merge-time record, which already needs
# the instance, reads it through the host's one tea login instead. Both
# consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time and binds a GitLab
# merge by identity only.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
PR_TREE=
if [ "$KEEP_BINDING" -eq 1 ]; then
  PR_HEAD=$PRIOR_HEAD
  PR_TREE=$PRIOR_TREE
elif [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
    # The tree is recorded only when this copy already has the head; a binding
    # without one is still bound by its head.
    PR_TREE=$(git -C "$WT" rev-parse --verify --quiet "$PR_HEAD^{tree}" 2>/dev/null || true)
    fm_pr_head_valid "$PR_TREE" || PR_TREE=
  fi
elif [ "$PROVIDER" = gitea ] && [ "${FM_PR_CHECK_MERGE:-}" = 1 ] && command -v jq >/dev/null 2>&1; then
  # Honored only when the answer describes exactly this pull request, because
  # tea resolves the instance from its login rather than from the URL.
  if REMOTE_HEAD=$(tea api --login "$GITEA_LOGIN" "/repos/$FM_PR_OWNER/$FM_PR_REPO/pulls/$NUMBER" 2>/dev/null       | jq -r --arg url "$URL" 'if type == "object" and .html_url == $url then (.head.sha // "") else empty end' 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
    if [ -n "$WT" ] && [ -d "$WT" ]; then
      PR_TREE=$(git -C "$WT" rev-parse --verify --quiet "$PR_HEAD^{tree}" 2>/dev/null || true)
      fm_pr_head_valid "$PR_TREE" || PR_TREE=
    fi
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
PR_POLL_PUBLISH_LOCK=
PR_POLL_PUBLISH_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$PR_POLL_PUBLISH_LOCK_HELD" = 1 ]; then
    fm_lock_release "$PR_POLL_PUBLISH_LOCK" || true
    PR_POLL_PUBLISH_LOCK_HELD=0
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
if [ "$KEEP_BINDING" -eq 0 ]; then
  fm_pr_binding_write "$STATE" "$ID" "$URL" "$PR_HEAD" "$PR_TREE" "$BINDING_REASON" \
    || { echo "error: could not record the PR binding for task $ID" >&2; exit 1; }
fi
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
if [ "$KEEP_BINDING" -eq 0 ] && [ -n "$PRIOR_URL" ] \
  && { [ "$PRIOR_URL" != "$URL" ] || [ "$PRIOR_HEAD" != "$PR_HEAD" ]; }; then
  printf 'notice: task %s is now bound to %s at head %s (was %s at head %s); present the changed PR and its diff stat (bin/fm-review-diff.sh %s --stat) to the captain before any merge\n' \
    "$ID" "$URL" "${PR_HEAD:-<unrecorded>}" "$PRIOR_URL" "${PRIOR_HEAD:-<unrecorded>}" "$ID" >&2
fi

PR_POLL_PUBLISH_LOCK="$STATE/.pr-poll-publish-$ID.lock"
fm_lock_acquire_wait "$PR_POLL_PUBLISH_LOCK"
PR_POLL_PUBLISH_LOCK_HELD=1
if fm_pr_poll_publish_prepared; then
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
else
  fm_lock_release "$PR_POLL_PUBLISH_LOCK" || exit 1
  PR_POLL_PUBLISH_LOCK_HELD=0
  echo "error: could not publish PR poll" >&2
  exit 1
fi
# The contribution observer uses the same authenticated check mechanism and
# owns verdict freshness, required actors and external feedback separately from
# the exact merged-state poll. Registration is local and performs no forge read.
if command -v jq >/dev/null 2>&1; then
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null \
    || printf 'contributions: observation not armed; coverage is unconfirmed\n' >&2
else
  printf 'contributions: jq unavailable; coverage is unconfirmed\n' >&2
fi
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR-ready line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A main home has no channel and this is a
# silent no-op there. The poll is armed either way; a channel that cannot be
# written is reported as actionable, and bin/fm-inactive-reconcile.sh still
# delivers the child's own ready line on the next supervision poll.
READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its ready line did not reach the parent channel (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
