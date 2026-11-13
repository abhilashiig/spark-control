# Agent notes

Spark Control is a native macOS SwiftUI app (Swift Package, no Xcode project). See README.md for build and tests.

- Build: `./build-app.sh` · Self-check: `./Tests/run.sh` (run it after touching Transform, Models, Remote,
  TensorFold or Benchmark).

## Changelog

Every user-facing change (feature, fix, behaviour change) gets a line in `CHANGELOG.md` under
`## [Unreleased]`, in the same commit, under `### Added`, `### Changed`, `### Fixed` or `### Removed`.
Write it for users, not as a commit log. Internal refactors and CI tweaks don't need an entry.

## Releases

Releases are cut from `main` by pushing a tag `vX.Y.Z`. `.github/workflows/release.yml` then runs the
self-check, builds the app, packs `SparkControl-vX.Y.Z.dmg` and publishes a GitHub release whose notes are
that version's CHANGELOG section. The workflow fails if that section is missing.

**Don't release on your own. Ask the user** when a release realistically matters, for example:
- a fix for a bug users hit (crash, broken model start, wrong API behaviour) has landed;
- a meaningful feature, or a few smaller ones, has accumulated under Unreleased;
- the user says they want to install, share or hand the app to someone.

Don't ask after every commit, for docs/CI/refactor-only changes, or while work is half done.

When the user agrees:
1. Pick the version (SemVer, but the user prefers small steps; most releases are patches):
   - **Patch** `X.Y.Z+1` (the default): fixes, polish, and small additions to an existing page or feature
     (a shortcut, a theme, a button, a setting). E.g. Terminal shortcuts + a theme fix → 1.8.1, not 1.9.0.
   - **Minor** `X.Y+1.0`: a new page, engine or major capability (e.g. adding the Terminal page itself),
     or several features at once.
   - **Major** `X+1.0.0`: breaking changes to config.json, the API or the gateway port; ask the user first.
   If the user names a version or a level, use theirs.
2. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and add a fresh empty
   `## [Unreleased]` above it.
3. Set `CFBundleShortVersionString` in `Resources/Info.plist` to `X.Y.Z` (CI stamps it from the tag
   anyway; this keeps local builds honest).
4. Commit `Release vX.Y.Z`, then `git tag vX.Y.Z && git push origin main vX.Y.Z`.
5. Tell the user the release will appear at https://github.com/abhilashiig/spark-control/releases once
   the workflow finishes.
