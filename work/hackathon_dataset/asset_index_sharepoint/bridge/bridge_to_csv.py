"""Collect asset-index-cloud's deal-bridge results for the hackathon deals into one CSV.

Grain: one row per (deal, tape column, CAT column, file) match that deal-bridge found,
plus one row for any deal it could not bridge. `is_bridge` marks the match deal-bridge
chose as the deal's bridge.

Reads data/dev/sorted/<KEY>/_meta/bridge.yaml in asset-index-cloud, which
`just deal-bridge <KEY> --env dev` writes. Re-run that first if the tapes change.

    uv run python work/hackathon_dataset/asset_index_sharepoint/bridge/bridge_to_csv.py
"""

from pathlib import Path

import pandas as pd
import yaml

SORTED = Path.home() / "data-warehouse/asset-index-cloud/data/dev/sorted"
OUT = Path(__file__).parent / "bridge_scan.csv"
DEALS = ["HEI-SE17039", "LOK-SE25008", "LOK-SE25013", "LOK-SE25014"]


def rows(key: str) -> list[dict]:
    path = SORTED / key / "_meta" / "bridge.yaml"
    if not path.exists():
        return [{"deal_key": key, "note": "no bridge.yaml: deal-bridge did not finish"}]
    record = yaml.safe_load(path.read_text())
    holding = record.get("holding") or {}
    chosen = record.get("bridge") or {}
    base = {
        "deal_key": key,
        "intrum_id": ", ".join(holding.get("servicer_ids") or []),
        "cat_cases_by_instance": ", ".join(
            f"{k}: {v}" for k, v in (record.get("instances") or {}).items()
        ),
    }
    matches = record.get("matches") or []
    if not matches:
        return [{**base, "note": "deal-bridge found no column that joins CAT"}]
    out = []
    for m in matches:
        out.append(
            {
                **base,
                "is_bridge": all(
                    m.get(k) == chosen.get(k)
                    for k in ("file", "sheet", "header", "cat_column")
                ),
                "kind": m["kind"],
                "file": m["file"],
                "sheet": m.get("sheet"),
                "tape_column": m["header"],
                "cat_column": m["cat_column"],
                "tape_values_found_pct": m.get("tape_values_found_pct"),
                "cases_matched": m.get("cases_matched"),
                "cases_in_deal": m.get("cases_in_deal"),
                "cases_matched_pct": (
                    100 * m["cases_matched"] / m["cases_in_deal"]
                    if m.get("cases_in_deal")
                    else None
                ),
                "cases_matched_by_instance": ", ".join(
                    f"{k}: {v}"
                    for k, v in (m.get("cases_matched_by_instance") or {}).items()
                ),
                "weak": m.get("weak"),
                "one_to_one_pct": m.get("one_to_one_pct"),
                "tape_rows": m.get("tape_rows"),
                "unique_in_tape": m.get("unique_in_tape"),
            }
        )
    return out


if __name__ == "__main__":
    df = pd.DataFrame([r for key in DEALS for r in rows(key)])
    df.to_csv(OUT, index=False, float_format="%.5f")
    print(f"{len(df)} rows -> {OUT}")
