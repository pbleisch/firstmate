# Gitea pull request watch verification

Empirical record for the merge watch on Gitea, alongside the existing GitHub and GitLab watches.
Every command below was run on 2026-08-09 and its output is reproduced exactly.

## Versions

```
$ tea --version
Version: development	golang: 1.26.1

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
```

## The evidence instances

Two instances appear below, for two different reasons.

The public part reads <https://codeberg.org/forgejo/forgejo>, a Gitea-family instance whose pull requests are readable with no credential, so a reader can rerun those commands and see the same output.
It is used only for the one fact that needs no authentication: how a Gitea-family API reports a merged pull request.

The end-to-end part reads a private self-hosted instance, because the property being demonstrated is that the host is data rather than a constant and that a login is resolved from that host.
Its hostname appears verbatim in the transcripts; the instance itself is not reachable from outside its network, which is exactly the deployment this watch has to survive.
Every command against it is a read: `tea logins list`, `tea pulls <n>`, and the poll, which only ever reads.

## Why the merged boolean rather than the state

A Gitea pull request that was merged and one that was abandoned both report `state: closed`.
The only discriminator is the separate merged boolean, verified against the public instance:

```
$ python3 -c "
import json, urllib.request
for n in (13859, 13834):
    with urllib.request.urlopen(f'https://codeberg.org/api/v1/repos/forgejo/forgejo/pulls/{n}') as r:
        p = json.load(r)
    print(n, p['state'], p['merged'])
"
13859 closed True
13834 closed False
```

A state-based poll would therefore either miss every merge or fire on every abandoned pull request.
`tea` exposes the same distinction as `hasMerged` in its pull request detail output, and only the exact `true` token wakes firstmate, so a changed output format produces no wake rather than a false merge.

## Why the detail form rather than the list

`tea pulls list` has no index filter, so selecting one pull request from it means searching a page whose size the server clamps.
That fails silently into a permanent "not merged" once a repository outgrows one page.
`tea pulls <n>` addresses the pull request by index directly and is what the poll uses.

## How tea is pointed at an instance, and why the answer is bound to the stored URL

`tea` cannot be pointed at an instance by URL the way `glab -R <project URL>` can.
Its `--repo` takes a bare `<owner>/<repository>` slug, and the instance comes from `--login`, a name in tea's own configuration:

```
$ cd /tmp && tea pulls list --repo https://git.local.paulbleisch.com/pbleisch/mpfs --state all --fields index,state --output simple
NOTE: no gitea login detected, falling back to login 'gitea' in non-interactive mode.
Error: path segment [1] is empty
```

That fallback note is itself worth recording: with no `--login`, tea silently picks one rather than refusing, so the login is always passed explicitly.

The login is therefore resolved from the validated host, and accepted only when exactly one configured login serves it:

```
$ cd /tmp && tea logins list --output tsv
Name	URL	SSHHost	User	Default
gitea	https://git.local.paulbleisch.com	git.local.paulbleisch.com	pbleisch	false
```

That indirection is weaker than passing a URL, so the answer is additionally bound to the stored URL: the poll requires the `url` field tea returns to equal the stored URL exactly before honouring `hasMerged`.
The detail output carries it, one tab-indented field per line, with every string escaped onto its own single line so a pull request body cannot forge a field:

```
$ cd /tmp && tea pulls 1 --repo pbleisch/mpfs --login gitea --output json | grep -n '"state"\|"url"\|"headSha"\|"hasMerged"'
5:	"state": "closed",
12:	"url": "https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/1",
15:	"headSha": "2e836ccfb7ec983eb921579b48c2329dba145817",
18:	"hasMerged": true,
```

`tea` exits non-zero with no stdout on every failure, so the poll's silence-on-error contract holds:

```
$ cd /tmp && tea pulls 999 --repo pbleisch/mpfs --login gitea --output json
Error: The target couldn't be found.
$ echo $?
1
```

## End to end: arming and polling a real pull request

The instance holds one merged pull request and one open one, so both outcomes can be shown against real data:

```
$ cd /tmp && tea pulls 2 --repo pbleisch/mpfs --login gitea --output json | grep -n '"state"\|"hasMerged"'
5:	"state": "open",
18:	"hasMerged": false,
```

Three tasks were armed against a scratch home, two on the private instance and one on a host with no configured login:

```
$ bin/fm-pr-check.sh e1 https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/1
armed: state/e1.check.sh
$ bin/fm-pr-check.sh e2 https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/2
armed: state/e2.check.sh
$ bin/fm-pr-check.sh e3 https://gitea.example/o/r/pulls/7
error: watching a Gitea pull request requires exactly one tea login for https://gitea.example
$ echo $?
1
```

The third refusal is the one difference from the GitLab watch worth stating plainly.
`glab` can be handed a project URL, so a GitLab watch can be armed for any host.
`tea` cannot, so a Gitea watch can only be armed for a host tea is already configured to reach, and that is checked at arming rather than discovered as permanent silence later.

The stored record for the armed task, showing the host as data:

```
$ cat state/e1.pr-poll
gitea
https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/1
git.local.paulbleisch.com
pbleisch/mpfs
1
```

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ bin/fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ bin/fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
```

The merged pull request produces exactly one `merged` line.
The open one produces nothing.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ bash state/e1.check.sh
merged
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `tea` would otherwise be indistinguishable from a pull request that is never merged.
With `tea` removed from `PATH`, the poll stays silent even for the pull request that is genuinely merged:

```
$ PATH="$notea" bin/fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$notea" bin/fm-pr-check.sh e4 https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/1
error: watching a Gitea pull request requires tea on PATH
$ echo $?
1
```

A GitHub task is unaffected by a missing `tea`:

```
$ PATH="$notea" bin/fm-pr-check.sh e5 https://github.com/kunchenguid/firstmate/pull/2005
armed: state/e5.check.sh
```

## Arming checks configuration, not reachability

Both arm-time refusals above read local state only: whether `tea` is on `PATH`, and which logins tea has configured.
Neither contacts the instance.
A self-hosted Gitea is routinely off the network when its pull request is opened, and refusing to arm then would lose the watch for a reachability dip that the poll itself handles.

An unreachable instance costs nothing beyond a bounded check: every check runs under `FM_CHECK_TIMEOUT` (default 30s) with a process-group kill, and a merge that happens while the instance is unreachable is detected on the next reachable poll rather than missed, because the poll re-reads state every cycle rather than being edge-triggered.

## Upgrade path from an existing armed watch

The stored record and its provenance format are unchanged, so `fm-pr-poll-registration-v2` still parses and every GitHub and GitLab watch already armed keeps working untouched.
Unlike the GitLab change, this one needs no version bump and no migration.

## Merging, and what the watch does not cover

Merging a Gitea pull request is `bin/fm-pr-merge.sh`'s job, and its header owns that contract.
One fact from this instance, recorded on 2026-09-28, shapes it: `tea api` exits 0 on an HTTP error, so the merge path reads the status line `tea api -i` prints rather than the exit code.

```
$ cd /tmp && tea api -i --login gitea /repos/pbleisch/mpfs/pulls/99999 2>err >/dev/null; echo "rc=$?"; head -1 err
rc=0
HTTP/1.1 404 Not Found
```

A Gitea task records no `pr_head=`.
`tea` does expose the head commit as `headSha`, but only over the network, and reading it at arming would make arming wait on an instance that is routinely unreachable.
Both consumers already treat it as optional and resolve the head themselves: Gitea serves `refs/pull/<n>/head` exactly as GitHub does, so `bin/fm-review-diff.sh` fetches the pull head directly from the remote.

```
$ git ls-remote ssh://gitea@git.local.paulbleisch.com:2222/pbleisch/mpfs.git 'refs/pull/*'
2e836ccfb7ec983eb921579b48c2329dba145817	refs/pull/1/head
```

`bin/fm-teardown.sh` reads the head from the forge at teardown through `gh`, which cannot answer for a Gitea URL, so a Gitea task's landed-work test resolves through the provider-agnostic content check instead:

```
$ gh pr view "https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/1" --json state,headRefOid -q '.state'
no pull requests found for branch "https://git.local.paulbleisch.com/pbleisch/mpfs/pulls/1"
$ echo $?
1
```

## Scope of the provider tag

`/pulls/<n>` is a Gitea-family route, served by Gitea, Forgejo, and Gogs alike, and `tea` speaks to all three.
The `gitea` tag therefore names that family rather than one product.
