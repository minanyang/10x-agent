# Grill — walk the open decisions before drafting

`/10x:open`, `/10x:work` and `/10x:roadmap` read this before they draft. The skill says which kind of question it asks; this file says how.

## Facts are looked up, decisions are asked

Anything the code, git history or `gh` can answer is never a question: look it up. A question is a decision only the user can make — what the user should get, which of two workable designs to take.

## Map the decisions as a tree

List the decisions the draft depends on. A decision whose answer changes what the next one even is branches into it: "keep the old endpoint?" comes before "how long does it stay deprecated?".

## Ask in rounds

Each round asks every decision whose prerequisites are settled, numbered across the whole grill:

```
❓ **Q1 — <title>**: <question, options if useful>
➡️ <recommended answer>
```

Give a recommendation for every question, with its reason in a few words. Then wait for the answers. A question that depends on one still open this round waits for a later round; after the answers, map what they opened and ask the next round.

## Depth scales with the ticket

- **Small** — the change touches ≤ 3 files and its place is known: one short round, or state the assumptions and offer to skip the grill — the ticket's own open questions are still asked.
- **Larger** — go on in rounds until no decision is left unasked.

An open question the ticket itself states — its own words ask it — is always asked, whatever the ticket's size. Skipping the grill on a small ticket covers only the decisions the ticket does not raise.

## Stopping and assumptions

The user can end the grill at any point ("enough", "go with your assumptions"). Every decision not asked, and every open question the user skipped, goes into the draft's `## Assumptions` with the answer taken — the recommendation, unless the user said otherwise. A decision the user answered is written into the draft where it belongs, not into `## Assumptions`. Accepting the recommendations ("go with your recommendations") answers every question asked in that round: each answer is written where it belongs, not into `## Assumptions`.

The grill comes before the draft and never replaces the draft's approval stop.
