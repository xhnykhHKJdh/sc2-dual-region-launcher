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

CI uses both PowerShell 7 and Windows PowerShell 5.1. Test scripts are ASCII; paths
with non-ASCII characters are generated from character codes and JSON manifests
are always read as UTF-8. The test runner mocks only the module's process query; it
never launches or stops a real Battle.net process. An injected second-file write
failure verifies automatic rollback after the first metadata file changed.

The core suite has 44 scenarios. Both supported shells passed all 44 scenarios,
including their normal temporary-directory cleanup path. The runner resolves its
module and fixture helper relative to its own file, so invoking it by absolute path
also works from another working directory.

Regional build-name parsing covers the observed `B<number>-WIN` Windows suffix,
wrong numbers with that suffix, and rejection of all unrecognized trailing suffixes.
Archive restoration also covers the bounded known pre-update multi-Base mode,
unknown/ordinary multi-Base mode refusal, and duplicate target refusal before moves.
