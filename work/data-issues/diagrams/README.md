# diagrams/ — pictures for other people

One script per picture, writing a **PNG** (paste into Slack or a deck) and an
**SVG** (vector, edits in any browser or Figma) beside it. Redraw after a
measurement changes rather than editing the image:

```sh
cd ~/data-warehouse/local-workspace
uv run python work/data-issues/diagrams/who_is_who.py
```

| Picture | What it shows |
|---|---|
| `who-is-who.png` · `.svg` | Originator vs seller vs servicer vs agency — which of them is a real company key, which is only a name, and which is nothing we can use. Measured 2026-10-09. |

⚠ **Every number on a picture must exist in a write-up with the query behind
it.** `who-is-who` is backed by [`../../dbt/WHO-IS-WHO.md`](../../dbt/WHO-IS-WHO.md);
if a figure there changes, change it in the script and re-render.
