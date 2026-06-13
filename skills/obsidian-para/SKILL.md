---
name: obsidian-para
description: Administer an Obsidian vault through the scoped Obsidian MCP using the PARA method. Use for inbox processing, note classification, moving or renaming notes, creating notes and indexes, archiving inactive material, cleaning vault structure, and deciding whether information belongs in Projects, Areas, Resources, or Archive.
---

# Obsidian PARA

Use only tools from the MCP server named `obsidian` for vault reads and writes.
Do not use terminal, shell commands, generic file tools, Git commands, or direct
filesystem paths to inspect or modify vault content. If `obsidian` MCP is not
available, stop and report that limitation instead of bypassing it.

Read [references/para-map.md](references/para-map.md) before classifying or
moving notes.

## Workflow

1. Call `list_allowed_directories` and confirm the scoped vault root.
2. Inspect only the required folders with `list_directory`, `directory_tree`,
   `search_files`, `read_text_file`, or `read_multiple_files`.
3. Classify each note by its current use:
   - `Projects`: active work with a concrete outcome and an end condition.
   - `Areas`: ongoing responsibility or standard with no finish date.
   - `Resources`: reusable reference or topic material with no active outcome.
   - `Archive`: inactive material retained for history or possible reuse.
   - `Inbox`: unprocessed capture only, never a permanent category.
4. Prefer the smallest useful change. Do not create a new folder when an
   existing destination fits.
5. Before bulk changes, show a concise proposed move table and ask for
   confirmation. A bulk change is more than one move, rename, overwrite, or
   deletion.
6. Execute approved moves with `move_file`. Create missing directories with
   `create_directory`. Use `edit_file` for focused edits and `write_file` only
   for a new note or an intentional full rewrite.
7. Re-read or list affected paths through MCP and report the actual result.

## Classification Rules

- Classify by actionability, not by subject. Notes about the same subject may
  belong to different PARA categories.
- A project note must name an observable outcome. If it describes maintenance,
  habits, health, finances, career, or another continuing responsibility, use
  an Area.
- Put source material, summaries, people, books, tools, and evergreen knowledge
  in Resources unless they are currently supporting one active project.
- Move completed, cancelled, paused indefinitely, or obsolete material to
  Archive while preserving useful links.
- Keep attachments, templates, daily notes, scripts, and application metadata
  in their established support folders unless the user explicitly requests a
  structural migration.
- Do not infer that a note is stale from age alone. Read enough content to
  determine its current role.

## Note Quality

- Preserve existing frontmatter, embeds, block references, and wikilinks.
- Prefer descriptive titles and `[[wikilinks]]` over duplicated content.
- When splitting a mixed note, keep the original until the new notes are
  verified, then replace it with links or archive it after confirmation.
- Never delete notes or attachments without explicit confirmation.
- Record uncertainty instead of forcing a weak classification.
