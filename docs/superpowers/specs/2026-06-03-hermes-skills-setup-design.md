# Hermes Skills Setup Design

## Goal

Add a stable, idempotent tool that manages Hermes skills in the same operational
style as the existing Hermes, MCP, and gateway setup scripts.

The first version focuses on two safe skill types:

- `builtin` skills that already exist inside Hermes and only need stabilization
  or verification from this repository.
- `local` skills stored in this repository and synchronized into the Hermes data
  volume.

External skills from GitHub, npm, arbitrary URLs, or marketplaces are explicitly
out of scope for v1. They require source pinning, integrity checks, and stronger
trust controls before they are safe to automate.

## User Experience

The normal path stays one-command:

```bash
./setup.sh
./scripts/update.sh
```

Both commands call a new `scripts/setup-skills.sh` after Hermes and MCP sync. A
manual run is also supported:

```bash
./scripts/setup-skills.sh
```

The script prints the same status style as the rest of the repo:

- `[OK]` when a skill was installed, updated, backed up, or stabilized.
- `[SKIP]` when the current state already matches the config.
- `[WARN]` when a skill is enabled but cannot be fully validated.
- fatal errors only for unsafe configuration, missing required files, or missing
  Hermes runtime prerequisites.

Repeated runs must be harmless. A clean second run should not rewrite identical
files.

## Configuration

Add:

- `config/skills.toml.example`
- `config/skills.toml` generated from the example when missing

Example:

```toml
[google_workspace]
enabled = true
type = "builtin"
description = "Stable Google Drive/Docs skill for Hermes gateway use"
stabilize = true

[project_memory]
enabled = true
type = "local"
source = "skills/project_memory"
description = "Project-specific workflow and memory skill"
```

Common keys:

- `enabled`: boolean. Disabled skills are not installed or updated.
- `type`: `builtin` or `local`.
- `description`: human-readable purpose for logs and docs.

`builtin` keys:

- `stabilize`: optional boolean. When true, run the repository's stabilization
  flow for that built-in skill if one exists.

`local` keys:

- `source`: repo-relative path to the local skill directory.

`setup-skills.sh` mirrors `setup-mcp.sh` behavior:

- create `config/skills.toml` if missing;
- sync missing sections from the example;
- sync missing keys from the example for existing sections;
- leave user-edited values intact.

## Local Skill Layout

Local skills live under:

```text
skills/<skill-name>/SKILL.md
```

The script validates that:

- the source path is repo-relative;
- the resolved source path stays inside the repository;
- the skill name contains only safe characters: letters, numbers, `_`, `-`, and
  `.`;
- `SKILL.md` exists;
- no symlink escapes the repository or target skill root.

The v1 installer copies the whole skill directory. This allows future assets,
references, or helper scripts to travel with the skill without changing the
installer contract.

## Target Location

The target is the Hermes data directory inside the running container.

The script resolves it using the same convention as `setup-mcp.sh`:

- prefer `$HERMES_HOME` inside the container;
- fall back to `/home/hermes/.hermes` when `HERMES_HOME` is unavailable.

Local skills are installed into:

```text
<HERMES_HOME>/skills/<skill-name>/
```

All writes happen through `docker exec hermes ...` so the script operates on the
same runtime state Hermes actually uses.

## Install And Update Flow

For every enabled skill:

1. Validate config and source.
2. Resolve the target path.
3. Compare source and target.
4. If identical, print `[SKIP]`.
5. If target exists and differs, create a timestamped backup under:

   ```text
   <HERMES_HOME>/backups/skills/<skill-name>/<YYYYmmdd-HHMMSS>/
   ```

6. Copy the new skill into a temporary target directory.
7. Move the temporary directory into place atomically where the filesystem allows
   it.
8. Print `[OK]`.

The target must never be deleted before the new copy has been staged
successfully.

## Disabled Skills

For v1:

```toml
enabled = false
```

means "do not install or update this skill."

It does not remove an already installed skill. Automatic removal is intentionally
out of scope for the first version because deleting skills changes agent
behavior and can destroy local user edits. A future version can add an explicit
`remove = true` opt-in after backup and confirmation semantics are designed.

## Built-In Skills

Built-in skills do not copy files. They run named stabilization or verification
flows that already exist in this repository.

The first built-in target is:

```toml
[google_workspace]
enabled = true
type = "builtin"
stabilize = true
```

When enabled with `stabilize = true`, `setup-skills.sh` calls:

```bash
./scripts/stabilize-google-workspace.sh
```

The script should log a warning, not fail the whole skill sync, when the
Workspace token or gateway context is not ready yet. That matches the existing
Google Workspace documentation: OAuth may require a manual CLI step first.

## Security Model

The v1 trust boundary is deliberately narrow:

- local repository content is trusted;
- built-in Hermes skills are trusted;
- remote skill downloads are not supported.

The script rejects:

- absolute `source` paths;
- `..` traversal;
- unsafe skill names;
- missing `SKILL.md`;
- source paths that resolve outside the repository;
- target paths that resolve outside the Hermes skills directory;
- symlink escapes during copy.

The script should avoid shell-string command construction where user-controlled
values are involved. Names and paths must be passed as arguments to shell or
Python helpers where possible.

## Integration Points

`scripts/setup.sh`:

- run `setup-skills.sh` after `setup-mcp.sh`;
- keep gateway setup after skills so gateway behavior can rely on stabilized
  built-in skills.

`scripts/update.sh`:

- run `setup-skills.sh` during re-sync;
- do not auto-update any external skills because v1 has no external source
  support.

README:

- add `setup-skills.sh` to frequent commands;
- mention `config/skills.toml`;
- document that disabled skills are not automatically removed.

Docs:

- add `docs/skills/README.md`;
- document local skill layout, built-in Google Workspace stabilization, and the
  no-remote-sources policy.

## Tests

Add Bats coverage for:

- `config/skills.toml` is created from the example when missing;
- missing example sections and keys are synced without overwriting user values;
- enabled local skill copies `SKILL.md` into the target Hermes data directory;
- second run is idempotent and logs `[SKIP]`;
- changed local skill creates a backup before replacing the target;
- `enabled = false` does not install or remove the skill;
- unsafe skill name is rejected;
- unsafe source path is rejected;
- missing `SKILL.md` is rejected;
- built-in `google_workspace` invokes the stabilization script when configured.

Unit tests should cover parsing and path validation. Integration tests should use
the existing Docker sandbox pattern and stub `docker exec` behavior where a real
Hermes runtime is not necessary.

## Future Work

External skill sources can be added later with a separate design. That design
should include:

- allowlisted source hosts;
- pinned git commit or content hash;
- lockfile with resolved version and checksum;
- cached downloads;
- review-before-install mode;
- rollback command;
- update policy separate from install policy.

## Open Decisions Resolved For v1

- `enabled = false` does not remove installed skills.
- Local skills are copied as directories, not single files.
- Built-in skills are managed through explicit named flows, not generic Hermes
  internals.
- Remote skills are not supported in v1.
