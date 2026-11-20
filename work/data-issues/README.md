# `work/data-issues/` — problems in the data, kept where they can be found

One folder per source of trouble. Each holds the write-up, the queries that
measured it, and whether it is ours to fix or the counterparty's.

| Folder | What is in it |
|---|---|
| [`intrum/`](intrum/) | The Intrum feeds (CAT loan-level, PAM batch-level): undocumented codes, coverage gaps, and the open escalations |
| [`diagrams/`](diagrams/) | Pictures to show other people. `who-is-who.png` / `.svg` — originator vs seller vs servicer, and which of them we can prove. Redraw with `uv run python work/data-issues/diagrams/who_is_who.py` |

**Why these are not filed with the analysis that found them.** A data-quality
problem outlives the question that turned it up. Per `CLAUDE.md` Rule 6 it is a
conversation with the data team or the servicer, never a quiet model edit — so
it needs an address that does not disappear when the notebook does.

**Nothing here is a fix.** Every finding is measured and read-only. A model
change is a separate request against `brocc-data`.
