# Named worktrees

Zibra uses [Worktrunk](https://worktrunk.dev/) to make each worktree a named
branch instead of a detached checkout. Install it once on macOS:

```sh
brew install worktrunk
wt config shell install
```

Then use the repository Taskfile from the main worktree:

```sh
# Create branch `fix/link-crash` and its worktree.
task worktree:new BRANCH=fix/link-crash

# Inspect, commit, and publish its changes without finding its path.
task worktree:status BRANCH=fix/link-crash
task worktree:commit BRANCH=fix/link-crash MSG='Fix link navigation crash'
task worktree:push BRANCH=fix/link-crash

# After its PR is merged, remove both the worktree and now-redundant branch.
task worktree:remove BRANCH=fix/link-crash
```

`worktree:remove` is intentionally safe: Worktrunk refuses a dirty worktree
or branch whose changes have not been integrated. `worktree:discard` is the
explicit destructive escape hatch for an abandoned change.

Task commands cannot change the directory of the invoking shell. For terminal
navigation, use Worktrunk directly after enabling shell integration:

```sh
wt switch fix/link-crash
```

Open that directory in whichever editor you prefer; editor integration is not
part of the repository workflow.

See `task --list` for all repository wrappers.
