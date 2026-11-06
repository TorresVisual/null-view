---
name: file-issue
description: Turns a rough, badly-worded bug report or feature idea into a proper GitHub issue for this repo — investigates the code and docs for context, checks for duplicates, asks the user about anything ambiguous, drafts title/body/labels for review, then files it with gh issue create. Use whenever the user hands you a rough note, a half-formed idea, a phone-test failure, or a log snippet and wants it tracked ("file this", "make an issue for", "track this"), even if they don't say "issue".
---

# Filing a GitHub issue from a rough note

## Why this exists

GitHub Issues are the tracker for bugs and features. The user's raw notes
arrive terse, garbled, or half-finished ("pip drops out sometimes", a
sentence that trails into a pasted log). Filed as-is, a future session with
no memory of this conversation has nothing to act on. This skill does the
enrichment and the asking before anything gets created.

## Steps

1. **Read the raw note(s)** the user typed, pasted, or pointed at. Resolve
   the target repo once with `gh repo view --json nameWithOwner -q .nameWithOwner`
   and use that everywhere below — never a hard-coded name, since this skill
   gets copied between projects.
2. **Investigate before asking.** Anything you can answer from the repo, don't
   ask the user:
   - Read the project's CLAUDE.md and its decision/roadmap docs (here
     `docs/decisions.md`, then `docs/brief.md`; elsewhere `docs/ROADMAP.md`
     or similar). Is the note about something already shipped, already cut,
     or contradicting a recorded decision? A note can be stale.
   - Grep/read the relevant code path so the body names real
     files/functions/line numbers, not just the symptom. That is what makes
     it fixable by a session that starts cold.
   - Search for duplicates: `gh issue list --state all --search "<keywords>"`.
     If one exists, show it to the user and offer to comment instead of
     filing a second.
3. **Ask about what's left.** Vague repro with no steps or device/OS, unclear
   scope (bug vs. feature vs. already-done), or a conflict with a documented
   decision: ask in plain text, batched into one message. Don't guess a fix,
   don't fabricate repro steps, don't silently drop an item that looks stale.
   If the work would break a decision in `docs/decisions.md`, that is the
   owner's call — say so rather than filing it as routine.
4. **Draft, per item:**
   - Title: short and specific, no `bug:`/`feature:` prefix (labels carry that).
   - Body: what happens vs. what's expected; exact repro steps only if the
     user gave them (otherwise "not yet reproduced" plus what is known);
     `file:line` pointers; suspected cause if you found one, marked as
     suspected; links to relevant docs or issues; and for app bugs the
     environment the user reported (device, iOS version, build). Quote pasted
     logs in a fenced block, trimmed to the relevant lines.
   - Labels: pick from `gh label list`, and only from there — an unknown
     label makes `gh issue create` fail. `bug` or `enhancement` at minimum;
     add `question`, `documentation`, etc. when they fit. Don't invent
     severity or area labels; put impact in the body instead. Suggest a new
     label to the user rather than creating one.
   - Don't state that something works or is broken in Swift/iOS code unless
     it was run on the Actions runner or the phone. On this PC the code
     can't be compiled, so mark such claims as unverified.
5. **Show the full batch of drafts and wait for approval or edits. Never call
   `gh issue create` before this.** Put the unambiguous drafts in one review
   pass; handle the ones that needed answers in a follow-up batch.
6. **On approval, file each.** Write the body to a temp file and pass
   `--body-file`, because multi-line bodies with quotes or backticks get
   mangled when inlined in a shell on Windows:
   `gh issue create --title "..." --body-file <file> --label bug`
   Report each issue number and URL back.
7. **If the note came from a tracker file** (a TODO list, a notes section),
   remove or mark that line once the issue is confirmed filed, so there is
   one source of truth. Leave plan and decision documents alone; those
   aren't issues.

## Verifying

`gh issue list --limit 5` — confirm the new issue(s) appear with the labels
you drafted.
