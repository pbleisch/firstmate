---
name: course
description: >-
  Assess whether each of the captain's projects and efforts is on course toward its own definition of success, and recommend what would get or keep it there.
  Use when the captain invokes /course (optionally /course <project>) or asks whether projects are on course, how a project is doing against its vision or goals, for a portfolio or direction review, or which projects deserve attention, parking, or ending.
  Also use when the captain answers a vision question an earlier /course report asked.
user-invocable: true
metadata:
  internal: true
---

# course

`/course` sits above `/bearings`.
Bearings says what is in flight; course says, per project, what success means, where the project stands against it, whether it is on course, and what to do next.
It is an assessment with a point of view, not a data dump: every claim rests on evidence, and every project ends with a verdict and recommendations.

## Authority

An invocation reads, judges, and writes exactly two kinds of file: its dated report, and a project's vision record when the captain confirms or corrects it.
It never dispatches, steers, merges, holds, answers a decision, or changes backlog or task state.
A recommendation becomes work only on the captain's word, through the normal lifecycle afterwards.
Project clones are read-only: read their files and git history as they are, and never fetch or check out in them.

## Scope

Plain `/course` covers every project and effort the captain has been working on:

- every project in `data/projects.md`;
- every secondmate scope in `data/secondmates.md`;
- every theme of active backlog work that is not one registered project, such as a research thread or a cross-project effort, named by a short kebab-case slug;
- every existing vision record, including parked and ended ones, which get one line each.

`/course <name>` narrows the assessment to that one project or effort; the portfolio section then only notes how it competes with the rest for capacity.
In a secondmate home the scope is that home's own projects, and the summary reaches the captain through its parent channel (`AGENTS.md` section 9).

## Evidence

Gather through the existing owners, and add no new collector, parser, or fleet-state reader:

- `bin/fm-bearings-snapshot.sh --json` for current fleet state: work in flight, open captain decisions, queued gates, recent landings, reports, and secondmate homes; its header owns the fields and the `--all-*` reveals for a deeper view of one project.
  Its observational cache refresh is the only side effect allowed; the bearings reconcile-request step belongs to `/bearings`, not here.
- `bin/fm-tasks-axi.sh` reads (`list`, `show`) for the queue behind each project, and the done archive for older landings.
- The project's vision record (below), any charter the home keeps for it (a `Goal` line counts as a source), and a local secondmate home's `data/charter.md` for that mate's scope.
  Reach a remote secondmate home only through the snapshot.
- Scout reports and plans under `data/<id>/report.md` that concern the project, for the intended direction and the milestones a plan set.
- The project clone's README and `git -C projects/<name> log` for what has actually changed and when.
- The most recent earlier `data/course-*.md` report, only to state how a verdict moved since then; it is never evidence of current state.

Weigh outcomes over activity: a merged feature that moves a success criterion counts; a run of tooling fixes, refactors, or reverts that moves none is drift, however busy it looks.
Say so when evidence is thin or stale rather than filling the gap with optimism.

## Success definition

The success definition comes from the project's vision record, `data/visions/<name>.md`; [`docs/configuration.md` "Project visions"](../../../docs/configuration.md#project-visions-datavisions) owns its fields.
When no confirmed record exists, draft one from the evidence (charter Goal line, plan milestones, README, captain statements in reports and backlog notes), put it in the report marked plainly as a proposal, assess against it provisionally, and give the project the verdict "unclear success definition".
Ask the captain to confirm or correct each draft; group these asks at the end of the chat summary.
When the captain answers, inspect the current record and write or update it with the confirmed text, today's date as `Confirmed`, and the captain's own words as the source.
Never write a draft to the vision record, and never edit a confirmed record without the captain's word; a stale criterion or a passed review date becomes a recommendation instead.

## Assessment per project

For each project, in this order:

1. **Vision** - one line.
2. **Against each success criterion** - where it stands, with the evidence: landed work, open work, a report, a commit, a date.
3. **Verdict** - one of these, with the reason in one sentence:
   - **on course** - recent outcomes move the criteria or the current milestone, and nothing material blocks the next step;
   - **drifting** - work lands, but it does not move the criteria, or the milestone keeps slipping;
   - **stalled** - little or nothing has moved, usually behind a decision, a blocker, or capacity;
   - **off course** - the evidence says the current approach will not reach the vision, or the project has moved away from it;
   - **unclear success definition** - no confirmed vision record yet.
   A record whose stance is parked or ended gets one line saying so, plus any reason to revisit that stance.
4. **What is really holding it back** - the main risks and the true constraint, naming each captain decision it waits on.
5. **Recommendations** - one to three concrete next steps that would get or keep it on course, each marked as needing the captain's word or as something firstmate can start under existing authority.
   Prefer the step that removes the binding constraint over more of the same work.

## Portfolio view

Lead the report with the portfolio, before the projects:

- where the captain's attention gives the most leverage now, usually the decisions or vision confirmations that unblock the most;
- projects that look abandoned or no longer earn their capacity, as candidates to park or end, with the evidence;
- conflicts for the same capacity: worker lanes, quota, a shared reviewer, or the captain's own attention, and which project should win.

## Output

1. Write the report to `data/course-<YYYY-MM-DD>.md`, or `data/course-<YYYY-MM-DD>-<name>.md` for a narrowed run, replacing that day's file from scratch.
   Title, a three-sentence framing, the portfolio view, one section per project, then the open vision questions.
   As with bearings reports, this private file may use task ids, repository names, and full `https://...` PR URLs.
2. Put the report on the captain's reading list when this home has one (for example through a `reading-list` skill); otherwise give its path.
3. Reply in chat under `AGENTS.md` section 9: the portfolio headline, one line per project with its verdict and top recommendation, the vision questions awaiting the captain, and the report link.
   Name each recommendation that needs the captain's word as the decision it is.
