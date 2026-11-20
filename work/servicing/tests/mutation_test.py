"""Do the tests catch real mistakes? Break the query on purpose and see.

    uv run python work/servicing/tests/mutation_test.py     # ~3 minutes

Each mutant is one realistic mistake a person editing the query could make. The
suite is run against the broken copy (live, controls and design suites skipped: they do not
read the query file). A mutant the suite still passes is a blind spot, and is
reported as MISSED. Nothing is written to sigma_queries/; mutants live in a temp file.
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import _lib  # noqa: E402
import run   # noqa: E402

# (name, the mistake, text to find, what it is replaced with)
MUTANTS = [
    ("massey_as_intrum", "The two Arrow Global UK books read as Intrum (the old rule's mistake)",
     "WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND w.country_code = 'UK'\n            THEN 'Massey'",
     "WHEN ds.deal_source_name = 'ORGANIC ORIGINATED' AND w.country_code = 'UK'\n            THEN 'Intrum'"),
    ("legacy_spain_as_cerved", "Legacy Spain read as Cerved (the rule before the manager's)",
     "WHEN ds.deal_source_name IN ('ORGANIC ORIGINATED', 'LEGACY') AND w.country_code = 'ES'\n            THEN 'Gescobro'",
     "WHEN ds.deal_source_name IN ('ORGANIC ORIGINATED', 'LEGACY') AND w.country_code = 'ES'\n            THEN 'Cerved'"),
    ("window_includes_current", "L3M frame includes the current month",
     "ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)\n                                         AS collections_l3m_euro",
     "ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND CURRENT ROW)\n                                         AS collections_l3m_euro"),
    ("stock_rate_for_flows", "Collections converted at the month-end rate instead of the monthly average",
     "a.collections_local_currency     * f.rate_flow  AS collections_euro",
     "a.collections_local_currency     * f.rate_stock AS collections_euro"),
    # Dormant today: superseded versions in scope are zero-valued, so this cannot change a figure.
    # Guarded by edge.superseded_versions_carry_no_value, which fails the day that changes.
    ("no_version_filter", "Servicer forecast keeps every snapshot version (restatements counted twice)",
     "FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY AS f\n        WHERE f.period_end_date <= CURRENT_DATE()\n        QUALIFY f.snapshot_version = MAX(f.snapshot_version) OVER (",
     "FROM PROD.NPL_COMMON.FCT_PORTFOLIO_FORECAST_SERVICER_SNAPSHOT_MONTHLY AS f\n        WHERE f.period_end_date <= CURRENT_DATE()\n        QUALIFY f.snapshot_version >= MIN(f.snapshot_version) OVER ("),
    # Not mutated: the accounting/underwriting version filters. Both facts hold one
    # version per portfolio-month today, so removing the filter changes nothing and
    # no test can see it. edge.single_version_plans fails the day that changes.
    ("forecast_wrong_month", "Underwriting forecast joined to the previous month",
     "ON uf.portfolio_sk = a.portfolio_sk\n        AND uf.period_end_date = a.period_end_date",
     "ON uf.portfolio_sk = a.portfolio_sk\n        AND uf.period_end_date = LAST_DAY(DATEADD(MONTH, -1, a.period_end_date))"),
    ("case_divisor_from_money", "Case window divides by months with collections, not months with case data",
     "COUNT(c.collected_cases_count) OVER (PARTITION BY c.portfolio, c.original_currency\n            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)\n                                         AS months_in_case_l3m_window",
     "COUNT(c.collections_euro) OVER (PARTITION BY c.portfolio, c.original_currency\n            ORDER BY c.month_index RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING)\n                                         AS months_in_case_l3m_window"),
    ("lost_amount_wrong_column", "Lost amount reads the jitter-out column",
     "collected_amount_local_lost_last_month_sum        AS case_lost_value_local",
     "collected_amount_local_jitter_out_last_month_sum  AS case_lost_value_local"),
    ("commission_sign", "Commission sign not flipped",
     "-a.commission_local         * f.rate_flow      AS commission_euro",
     " a.commission_local         * f.rate_flow      AS commission_euro"),
    ("loading_month_leaks", "The last-complete-month guard removed",
     "WHERE w.month_end <= lcm.month_end",
     "WHERE w.month_end <= CURRENT_DATE()"),
]


# A mutant that cannot change today's data is not a blind spot if a check guards the
# condition that keeps it harmless. Name that check here.
DORMANT_GUARDS = {"no_version_filter": "edge.superseded_versions_carry_no_value"}


def _guard_holds(suites, check_id: str) -> bool:
    for m in suites:
        for c in m.CHECKS:
            if c.id == check_id:
                return round(abs(float(c.actual()) - float(c.expected())), 2) == 0
    return False


def main() -> int:
    original = _lib.PROPOSED_SQL.read_text()
    suites = [m for m in run.load(None) if m.SUITE not in ("live", "design", "controls")]
    print(f"{len(MUTANTS)} mutants against {sum(len(m.CHECKS) for m in suites)} checks\n")
    missed = 0
    for name, what, find, replace in MUTANTS:
        if find not in original:
            print(f"  STALE   {name:<26} the text to mutate is no longer in the query - update this mutant")
            missed += 1
            continue
        with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
            fh.write(original.replace(find, replace, 1))
        _lib.PROPOSED_SQL = pathlib.Path(fh.name)
        _lib._FRAMES.pop("proposed", None)
        caught, errors = [], []
        for m in suites:
            for c in m.CHECKS:
                try:
                    a, e = float(c.actual()), float(c.expected())
                except Exception as exc:   # a crashing check proves nothing - never count it as a catch
                    errors.append(f"{c.id}: {str(exc).splitlines()[0][:60]}")
                    continue
                drift = abs(a - e) / abs(e) if e else abs(a - e)
                if not (drift <= c.tol if c.tol else round(abs(a - e), 2) == 0):
                    caught.append(c.id)
        if errors:
            print(f"  ERROR   {name:<26} {len(errors)} check(s) crashed, e.g. {errors[0]}")
            missed += 1
            pathlib.Path(fh.name).unlink()
            continue
        guard = DORMANT_GUARDS.get(name)
        status = "CAUGHT" if caught else ("DORMANT" if guard and _guard_holds(suites, guard) else "MISSED")
        missed += 0 if status != "MISSED" else 1
        print(f"  {status:<7} {name:<26} {what}")
        if caught:
            print(f"          by {len(caught)} check(s), e.g. {', '.join(caught[:3])}")
        elif status == "DORMANT":
            print(f"          cannot change any figure in today's data; {guard} passes and will fail the day it can")
        pathlib.Path(fh.name).unlink()
    _lib.PROPOSED_SQL = pathlib.Path(__file__).resolve().parent.parent / "sigma_queries" / "portfolios_element.sql"
    print(f"\n{len(MUTANTS) - missed} of {len(MUTANTS)} deliberate mistakes caught or guarded; {missed} blind spot(s)")
    return 1 if missed else 0


if __name__ == "__main__":
    raise SystemExit(main())
