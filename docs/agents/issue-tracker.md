# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`.
- **Read an issue**: `gh issue view <number> --comments` and fetch labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments` with appropriate label and state filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- **Close an issue**: `gh issue close <number> --comment "..."`.

Infer the repository from the current clone's GitHub remote.

GitHub shares one number space across issues and PRs. For an ambiguous reference, resolve with `gh pr view <number>` and fall back to `gh issue view <number>`.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Publishing

When a skill says to publish to the issue tracker, create a GitHub issue.

## Fetching tickets

When a skill says to fetch the relevant ticket, run `gh issue view <number> --comments` and fetch labels.

## Wayfinding operations

Used by `/wayfinder`. The map is a single issue with child issues as tickets.

- **Map**: create an issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- **Child ticket**: link an issue to the map as a GitHub sub-issue using `gh api`. Where sub-issues are unavailable, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Use `wayfinder:<type>` labels: `research`, `prototype`, `grilling`, or `task`.
- **Blocking**: use GitHub's native issue dependencies. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. Obtain the blocker's database ID with `gh api repos/<owner>/<repo>/issues/<number> --jq .id`; this is not its issue number or node ID. Where dependencies are unavailable, put `Blocked by: #<number>, #<number>` at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children, scoped to its sub-issues or task list. Exclude assigned tickets and tickets with open blockers (`issue_dependencies_summary.blocked_by > 0`, or open issues referenced by the fallback `Blocked by` line). First in map order wins.
- **Claim**: `gh issue edit <number> --add-assignee @me`, the session's first write.
- **Resolve**: comment with the answer, close the child issue, then append a context pointer (gist and link) to the map's Decisions-so-far.
