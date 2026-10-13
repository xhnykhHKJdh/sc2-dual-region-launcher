# Synthetic verification matrix

These tests use generated data beneath a temporary test directory. They must never
discover, read, or modify a real Battle.net installation, database, account, or
desktop shortcut. No Pester dependency is required.

## Fixture design

- **Product database:** minimal protobuf records for `s2_cn`, `s2`, and `s2t`, plus
  synthetic unknown fields of wire types 0, 1, 2, and 5. Place unknown fields before,
  inside, and after relevant records. Preserve their exact encoded bytes, including
  deliberately noncanonical but valid varints.
- **Hidden metadata:** generate `.product.db` and `.build.info`; on Windows assign
  Hidden and System attributes to the metadata fixture. Verify replacing content
  succeeds and retains intended attributes.
- **Installed skeleton:** use tiny marker files named `StarCraft II.exe` and
  `SC2Data/synthetic.data`, plus a `Versions` directory. These files are synthetic
  markers only and are never executed.
- **Build information:** generate `.build.info` with realistic pipe-separated
  headers, arbitrary column order, CRLF, extra columns, dynamic 32-character build
  and CDN keys, active and inactive rows, and distinct CN/EU builds.
- **Versions:** generate synthetic `Base<number>` directories containing tiny marker
  files. Include a copied CN build, current EU build, inactive EU build, older CN
  build, unrelated high build, and nonnumeric directory. Metadata provides all
  evidence; directory names alone are insufficient.
- **Build config:** use `build-name = B50913` as the primary format and separately
  verify matching full-version compatibility. CN/EU fixture build numbers are
  `51029` and `50913`, intentionally different from the machine's real versions.
- **Agent state:** supply an injectable process query or a clearly documented
  synthetic offline predicate. Do not launch or terminate Battle.net or Agent.
- **Filesystem:** use separate CN/EU trees and negative cases for identical paths,
  case/separator differences, nested paths, and a directory symlink or Windows
  junction.
- **Backups:** generated source files have known SHA256 values. Corrupt a source,
  candidate, backup, or manifest separately to test refusal and rollback safeguards.

## Risk matrix

| Area | Required positive check | Required refusal or failure check |
| --- | --- | --- |
| Protobuf preservation | Only intended `s2` path/region changes; `s2_cn`, `s2t`, unknown fields, and untouched wrappers retain raw bytes | Truncated message, invalid wire type, ambiguous `s2`, missing product, invalid UTF-8 where a text change is required |
| Existing EU metadata | Missing metadata, exact CN copy, or proven matching direct `s2` record is accepted | Unrelated installed products, unknown unproven wrapper fields, or contradictory local state reject |
| Hidden metadata | Write succeeds for a hidden fixture; retained attributes are verified | Source changes after preparation; no partial write |
| Offline operation | Preparation/application with no matching process succeeds | A supplied Agent/Battle.net process blocks application and rollback before any write |
| Paths | Distinct, explicit synthetic CN/EU roots succeed | Identical, normalized-equivalent, nested, directory symlink/reparse roots reject |
| Build selection | Uses dynamic EU build/CDN keys and matching `.build.info` rows | Missing, duplicate, contradictory, malformed, or ambiguous active build evidence rejects |
| International discovery: matching branches | Separated `us` and `kr` registrations with corresponding active build branches retain their verified paths, keys, and versions without changing fixture hashes | Incomplete or contradictory build evidence rejects |
| International discovery: cross-region builds | Matching Agent/local `us` or `kr` registration may retain an `eu` active build branch, with verified keys/versions and unchanged fixture hashes | A recognized region does not replace key/version verification |
| International discovery: unsupported region | Supported `eu`/`us`/`kr` registration remains read-only | `cn`, unknown, or unrecognized international registration rejects without changing files |
| International discovery: registration agreement | Agent and game-local product registration have the same international region | Agent/local region mismatch rejects without changing files |
| International discovery: branch boundary | Only international `eu`/`us`/`kr` active build branches are eligible | International `cn`, unknown, or PTR-like active branch rejects without changing files |
| CN discovery: strict branch | CN retains its required `cn` active build branch | International branch flexibility never permits a CN `us` active build row; rejection leaves files unchanged |
| Versions handling | Only a proven copied CN build newer than the proven EU build may move into recoverable quarantine | Older/equal CN, current/inactive EU, unrelated high build, nonnumeric, or unproven copy is left in place |
| Backup | Backups and manifest match original hashes; repeat operation never overwrites the previous backup | Altered backup/manifest rejects; failure during commit restores every changed file |
| Rollback | Verified rollback restores source bytes/attributes and eligible moved directory | Source modified by another process, stale candidate, missing backup, hash mismatch, active Agent, or quarantine collision refuses |
| Dry run | Reports proposed changes with no source writes and no moves | Wrong fixture path or incomplete evidence fails clearly |
| Portability | Works from any working directory and with spaces/non-ASCII in paths | Accidental reliance on a user-specific drive/install path is caught by temporary roots |

## Running and reporting

The runner fails with a nonzero exit code when any assertion fails and prints one
concise pass/fail line per scenario, followed by counts. The reparse-point guard is
mandatory; Windows junction creation is the fallback when symbolic links are
unavailable. Failed fixtures are preserved for diagnosis;
successful fixtures are removed only after verifying their resolved paths remain
inside the dedicated temporary test root.

Run from the repository root:

```powershell
& '.\tests\Run-Tests.ps1'
# Retain successful fixture files for manual inspection:
& '.\tests\Run-Tests.ps1' -KeepFixtures
```

CI uses both PowerShell 7 and Windows PowerShell 5.1. Core fixture scripts are ASCII;
their non-ASCII paths are generated from character codes. Launcher tests contain
localized captions and use UTF-8 with BOM for Windows PowerShell compatibility.
JSON manifests are read as UTF-8. The core runner mocks the module's process query;
launcher tests also mock regional launch, helper processes, signature reports, and
repair side effects. No suite launches or stops a real Battle.net process. An injected second-file
write failure verifies automatic rollback after the first metadata file changed.

The core suite has 44 scenarios. Both supported shells passed all 44 scenarios,
including their normal temporary-directory cleanup path. The runner resolves its
module and fixture helper relative to its own file, so invoking it by absolute path
also works from another working directory.

Regional build-name parsing covers the observed `B<number>-WIN` Windows suffix,
wrong numbers with that suffix, and rejection of all unrecognized trailing suffixes.
Archive restoration also covers the bounded known pre-update multi-Base mode,
unknown/ordinary multi-Base mode refusal, and duplicate target refusal before moves.

## One-click and GUI verification

The one-click suite has 30 scenarios in addition to the 44 core scenarios. It uses
synthetic discovery results, filesystem fixtures, and mocked launcher/process
operations rather than the machine's real Battle.net installation.

The launcher suite has 58 scenarios, and the hidden WinForms suite has 14.
Together with the 44 core and 30 one-click scenarios, the full runner contains
146 scenarios. Run either additional suite directly from the repository root:

```powershell
& '.\tests\Test-Launcher.ps1'
& '.\tests\Test-LauncherWindow.ps1'
```

The GUI adds a controller layer for automatic discovery, regional launch, and the
existing repair workflow. Controller tests use synthetic data and mock side effects:

- Inspection reads installation state without running repair.
- The CN button uses the detected official launcher and CN product. EU, US, and
  Asia share the international `s2` installation; launch refuses an unresolved
  CN/international shared-directory conflict.
- Five signature scenarios exercise the native startup guards using synthetic
  Authenticode reports. Only a valid signature with a recognized Blizzard publisher
  is accepted; unsigned or missing certificate data, invalid or untrusted
  signatures, other or misleading publisher names, and lookup errors stop CN
  startup, international client opening, and international helper startup before
  creating a process. These tests do not validate a real executable's signature.
- International actions require confirmed game-region evidence, not a Battle.net
  login-region argument. The native helper's generated result must match the
  requested EU/US/KR region, report confirmed game-region selection, and succeed
  before the controller reports a started game. Timeouts, malformed or missing
  results, mismatched regions, and helper exit failures reject success.
- The native region parser accepts supported English and Chinese official game
  captions with a complete game identity, target region, and version. Ambiguous
  captions, China, PTR, other games, unknown languages, and incomplete versions
  do not authorize a Play click. These parser checks use synthetic strings.
- Repair reuses the backup-and-split workflow. After a new split it opens the
  official international client with the EU login-region argument for
  validation/update, without a game launch argument; an already separated
  installation only gets shortcut upkeep.
- Unsupported discovery and operation failures produce a useful result without
  guessing paths or hiding the failure.

The 14 window scenarios construct real WinForms controls in memory while keeping
the form hidden and its timer stopped. Worker processes, results, and discovery
are synthetic; no desktop input, actual worker startup, repair, or region selection
is performed. These scenarios cover:

- Construction does not start inspection or a game. Read-only fields show the
  supplied paths and versions; supported, conflicting, and unsupported discovery
  enable only the appropriate actions.
- An active launch or repair disables repeated actions and region changes, and
  rejects closing until its result has been processed. A read-only inspection can
  close and disposes only its own synthetic worker.
- Completion restores controls and consumes the final log line once. Malformed,
  missing, or mismatched results clear stale launch authorization while keeping
  repair available for retry; failed inspection retains private evidence.
- EU/US/KR selection persists only the region enum, changes the button caption,
  and dispatches the matching launch action. Invalid preferences default to EU;
  reopening does not launch work or request editable path or account input.
- Successful inspection removes only its known `result.json` and `activity.log`
  files in the private GUID directory, preserving unrelated files and other jobs.
  Idle polling waits sixty seconds and then requests only inspection.

The complete 146-scenario runner passed on Windows PowerShell 5.1 and PowerShell
7.6.5 on 2026-10-14. A separate production read-only worker also returned
`Separated` for the current CN installation and international installation after
the official client's Americas registration change. The local native build record
and GUI executable subsystem were verified. CI also builds the native executable
from a clean checkout.

These hidden-control tests do not establish visible layout or message-loop
responsiveness on the user's desktop. A real-machine read-only window check must
not repeat the already completed installation repair. Regional selection/launch
checks need separate reporting and must not be described as a completed online
account login without that evidence.

The first start builds a local native host and region helper using the
Windows-provided .NET Framework compiler and Windows PowerShell 5.1. The host
keeps the WinForms scripts in the complete source folder; no third-party package
download is required. Command-line modules remain compatible with PowerShell 7.
The new automatic UI region helper has not completed an end-to-end startup check
against a real official client. A separate manual Europe-to-Americas game-region
selection displayed the same Play version. The five installation metadata hashes
were initially unchanged, but the official client later updated the product region
to `us` asynchronously while the downloaded build branch remained `eu`, with the
same build key and version. That immediate snapshot does not establish
permanent metadata stability, or an Americas or Asia online login. The tool does
not write installation metadata to select an international game region; the official
client may update its records. Separated international installations accept regions
and build branches within `eu`, `us`, or `kr`; the registration region and branch
may differ, while Agent/local registration-region agreement and build-key/version
verification still apply. The prior
real-machine repair and player-confirmed CN/EU logins remain separate evidence.
Real account configuration,
private operation logs, preferences, game data, and installation databases must
never become test fixtures.
