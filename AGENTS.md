# Development and publication

## Development

- Preserve existing test, packaging, installation, and local deployment procedures.
- Run the project's existing validation commands before promoting a change.
- Keep private configuration, credentials, customer data, and backup files out of commits and release packages.
- Commits carry only the repository owner's identity. Do not add co-author trailers for assistants or tools.
- Preview public changes and obtain the repository owner's approval before publishing.

## Changes to main

1. Fetch public main and prepare a short-lived branch from the current public history.
2. Include only the intended changes; do not import private development history.
3. Push the branch, open a pull request targeting main, and review the diff and available checks.
4. Merge the pull request. The initial solo-maintainer baseline requires no second-person approval.
5. Refresh the public clone after merging without discarding unrelated local changes.

Direct pushes, force pushes, and deletion of public main are prohibited. Do not bypass or weaken repository rules. New required CI checks and Git commit-signing requirements must be established and approved before they become blocking.

## Releases

1. Use a new version and create its v-prefixed tag on the intended commit already merged into public main.
2. Never move, delete, or reuse an existing version tag.
3. Use the existing packaging procedure on the reviewed release source. Complete any configured signing before packaging.
4. Create a draft release and upload all intended assets before publication. Check the tag, commit, version, asset inventory, and hashes.
5. Publish the complete draft. Published assets are immutable; a correction requires a new version.
6. If configured, confirm the attestation workflow succeeds for the distributed files. A source-only fallback does not attest a missing release ZIP.

## Security and recovery

Keep secret scanning and push protection enabled. Do not routinely bypass alerts. Dependency scanning is not a replacement for the project's tests and analysis. Follow SECURITY.md for sensitive reports. Maintain versioned backups of public Git history, release assets, and settings outside the repository; keep an additional copy off the development machine.

For a new public repository, configure these branch/tag protections and future-release immutability before the first release. Enable dependency graph, Dependabot alerts, secret scanning, push protection, and private vulnerability reporting. Personal-account repositories do not automatically inherit these settings. Automatic merges and automated dependency-update pull requests are not part of this baseline.

## Proposed CI baseline

Read `.github/ci.json`. Use the existing `Run-Tests.ps1` on both PowerShell editions and `tools\New-TsPackage.ps1` for packaging; do not change runtime behavior, measured data or version merely to align CI.

The proposed required contexts are `Validate (PowerShell 7)` and `Validate (Windows PowerShell 5.1)`, from GitHub Actions (app ID 15368). Establish successful hosted runs before making them blocking. PSScriptAnalyzer diagnostics and CodeQL findings remain advisory; syntax, scan execution, tests and the package gate must succeed. CodeQL covers Actions and the production C# reader, not PowerShell.

The advisory C# job uses manual compilation through `.github\scripts\Build-CodeQLProduction.ps1` and `.github\codeql\Production.proj`. It compiles every production `src\*.cs` recursively against the running PowerShell framework references, without NuGet restore or executing/loading the tool. Outputs stay outside the runtime package; do not distribute them. The build manifest checks source/reference inventories, but only the hosted CodeQL tracer/database diagnostics can establish complete extraction. This analysis-only PowerShell 7 build does not replace the existing Windows PowerShell 5.1 runtime tests.

Actions are pinned to reviewed commit IDs; any pin update also needs an explicitly approved actions-policy update. Checkout must retain event-revision semantics, no persisted credentials, no `pull_request_target`, and the exact `Nico77600/TransportSizer` job guards. Release attestation requires actual immutable published ZIP assets; no fabricated release or source-only fallback.
