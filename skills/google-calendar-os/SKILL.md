---
name: google-calendar-os
description: Plan and administer Google Calendar as a time-blocking system integrated with todoist-os. Use for daily and weekly planning, inserting protected work or personal blocks, arranging errands by route, assigning phone tasks to transit or waiting windows, adding preparation and travel buffers, resolving calendar overload, and converting Todoist estimates and contexts into realistic calendar blocks.
---

# Google Calendar OS

Load and follow both `google-workspace` and `todoist-os` before planning or
changing the calendar. Todoist owns actions; Calendar owns fixed commitments,
travel, appointments, and protected execution time.

Read [references/current-system.md](references/current-system.md) for the
observed calendar conventions. Read
[references/context-planning.md](references/context-planning.md) when planning
routes, transit, errands, or opportunistic work.

## Sources

1. Read the relevant Google Calendar range.
2. Read Todoist Today, overdue, p1/p2, and tasks dated inside the planning
   range.
3. Use Todoist `context`, `estimate`, `mode`, status, date, deadline, and
   project fields. Do not infer that all Todoist tasks need calendar events.
4. Ask at most one question only when a missing location, travel mode, fixed
   deadline, or energy constraint would materially change the plan.

## Planning Order

1. Preserve fixed commitments, appointments, classes, travel, and sleep.
2. Add realistic preparation, travel, check-in, and recovery buffers.
3. Place p1 work and real deadlines.
4. Protect deep-work tasks of at least one hour.
5. Batch multimodal work by project or tool.
6. Attach physical errands to an existing route or destination.
7. Fill usable transit and waiting windows with short phone tasks.
8. Leave slack. Do not fill every open minute.

## Context Rules

- `👨‍💻 Глубокая работа`: schedule a protected, interruption-free block.
  Prefer one task per block. Never place it in transit or a fragmented gap.
- `🧑‍💻 Мультимодальная работа`: batch related 10–30 minute tasks in a
  lower-energy block.
- `💻 Компьютер`: require a stable workstation unless the task is explicitly
  laptop-safe.
- `📱 Телефон`: may fit a bus, train, queue, waiting room, or passenger window
  when connectivity and privacy are adequate.
- `💪 Физически`: combine with destinations already on the route. Prefer one
  geographic cluster over separate trips.
- Never schedule phone or computer work while the user is driving, cycling, or
  otherwise responsible for navigation and safety.

## Calendar Blocks

- Keep fixed events specific: concrete title, start/end, timezone, and
  `location` for physical destinations.
- Keep Todoist actions in Todoist. A calendar event protects execution time and
  may reference one task or a small coherent batch in its description.
- Use the Todoist estimate as the baseline duration. Add setup and shutdown
  overhead when the task requires files, travel, equipment, or context
  switching.
- Split blocks longer than two hours unless the activity is inherently
  continuous. Add a break to long study or work sessions.
- Do not combine independent deep tasks in one vague event.
- Use all-day events only for day-level facts, not as substitutes for tasks.
- Use the current calendar style: concise Russian title and an optional leading
  emoji when it improves scanning.

## Route Optimization

For each physical commitment, identify:

- destination and geographic area;
- departure and arrival windows;
- travel mode;
- nearby `💪 Физически` Todoist tasks;
- usable passenger/waiting windows for `📱 Телефон` tasks.

Prefer this sequence:

```text
fixed destination -> nearby errands -> return/next destination
transit as passenger -> short phone batch
waiting buffer -> optional phone task
```

Do not add an errand when it makes a fixed event fragile. Preserve a lateness
buffer and account for opening hours when known.

## Change Protocol

1. Show the proposed schedule before mutation.
2. Include event title, exact start/end with UTC offset, location, linked
   Todoist task or batch, and reason for placement.
3. Require confirmation before creating or deleting Calendar events, following
   the `google-workspace` safety contract.
4. After approval, use the Google Workspace calendar API.
5. Re-read the affected range and report the actual result.
6. Do not complete, reschedule, or rewrite Todoist tasks unless the user also
   approves those Todoist changes.

## Quality Gate

- No overlap with fixed commitments.
- Travel and preparation time are represented.
- Total scheduled work fits the available day.
- Deep work is not placed in transit or tiny gaps.
- Phone tasks fit the window and do not require unsafe attention.
- Physical errands share a plausible route.
- Block durations match Todoist estimates.
- Blocked and someday tasks are not scheduled.
- At least one recovery or slack window remains on a busy day.
