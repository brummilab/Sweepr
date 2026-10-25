# Security Policy

Mole CLI for Windows is a local system maintenance tool. It includes high-risk operations such as cleanup, uninstall, optimization, and artifact removal, so safety boundaries, deletion logic, and release integrity are treated as security-sensitive.

## Reporting a Vulnerability

Please report suspected security issues privately.

- Email: `hitw93@gmail.com`
- Subject line: `Mole Windows security report`

Do not open a public GitHub issue for an unpatched vulnerability. If GitHub Security Advisories private reporting is enabled for the repository, you may use that channel instead.

Include as much of the following as possible:

- Output of `mo --version` and how Mole was installed
- Windows version
- Exact command or workflow involved
- Reproduction steps or proof of concept
- Whether the issue involves deletion boundaries, junctions or symlinks, administrator access, path validation, or release and install integrity

## Response Expectations

- We aim to acknowledge new reports within 7 calendar days.
- We aim to provide a status update within 30 days if a fix or mitigation is not yet available.
- We will coordinate disclosure after a fix, mitigation, or clear user guidance is ready.

Response times are best-effort for a maintainer-led open source project, but security reports are prioritized over normal bug reports.

## Supported Versions

Security fixes are only guaranteed for the latest published `V<version>-windows` release and the current `windows` branch.

## What We Consider a Security Issue

- Path validation bypasses, including through junctions, symlinks, or `..` segments
- Deletion outside intended cleanup boundaries or of protected locations
- Commands that change the system in `--dry-run` mode
- Unexpected elevation or unsafe use of administrator access
- Release, installation, update, signature, or checksum integrity issues

## What Usually Does Not Qualify

- Cleanup misses that leave recoverable junk behind
- Mole refusing to clean something
- Cosmetic UI problems
- Requests for broader or more aggressive cleanup

If you are unsure whether something is security-relevant, report it privately first.

## Safety Boundaries

- PowerShell cleanup uses the helpers in `lib/core/file_ops.ps1`, which check protected paths and the whitelist and honor dry-run mode. Native Analyze and installer operations have separate guards.
- `C:\Windows`, `C:\Program Files`, `C:\Program Files (x86)`, Windows Defender folders, and the user profile root are protected; an empty or unparsable path counts as protected.
- Automatic cleanup generally deletes permanently. Verified uninstall leftovers use the shell's recycle-only operation; Analyze requests Recycle Bin behavior and a Windows warning if permanent deletion would be required. Third-party uninstallers retain their own removal semantics.
- The release process requires Authenticode signing and `SHA256SUMS.txt` for release assets. Downloaded prebuilt `analyze` and `status` tools are accepted only when their SHA-256 matches that list; a source review alone does not verify a published package.

See [the Windows CLI security review](SECURITY_AUDIT.md) for implementation boundaries, regression coverage and known limitations.
