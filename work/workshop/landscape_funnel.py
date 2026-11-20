"""The two pages that say what we can model on: one per deal, one per attribute.

Reads the label grids the workbook already builds -- nothing new is queried here. The
labels carry the reason a cell is unusable, which is what lets a blocker be named with the
owner of its fix.

Two principles, both deliberate:

    An attribute found either side counts as found. It does not matter whether a variable
    reaches us through the seller's tape or the servicer's feed, so long as it reaches us.
    The two sides are still shown, as the breakdown, but the headline is the union.

    Payment history from before registration is the exception. It is the one thing the
    servicer's feed almost never carries -- measured 2026-11-03, 2 deals of 2,281 -- so a
    deal either has it from the tape or does not have it at all. It gets its own column
    rather than being averaged into a count of attributes.

Everything is in deals and attributes, never in percentages: "usable on 222 of 224 deals"
answers the question a share only gestures at.
"""

from __future__ import annotations

import pandas as pd

from landscape_workbook import Sheet

# label -> (who fixes it, what it needs, how long, what the label means here)
# The effort and timeline are our judgement, not measured. Edit them here.
REASONS = {
    "Not Found: DBT Clean Up Required": (
        "Us - data team", "Carry it through into our warehouse", "Weeks",
        "We already receive it per loan. Only the modelling is missing."),
    "Not Found: Batch Level Only": (
        "Us - data team", "Decide how to split it to a loan, then model it",
        "Weeks, needs a decision first",
        "We hold it per batch, not per loan. Splitting it needs an allocation nobody has "
        "agreed, so this is a decision as much as work."),
    "Mainly Null (10%+)": (
        "Intrum", "Backfill the column", "Months",
        "The column reaches us, but 10% or more of loans are blank."),
    "Not Found: Not Sent by Servicer": (
        "Intrum", "Send the attribute at all", "Months",
        "The servicer does not send it."),
    "Not Found in a Table": (
        "Intrum", "Send it per loan", "Months",
        "The servicer sends nothing per loan for this deal."),
    "Unreadable": (
        "Us - data team", "Unlock the DRM-protected files", "Days",
        "The deal has seller files nobody can open; the attribute may be inside them."),
    "Not Found: No Data for Deal": (
        "Nobody", "Not recoverable", "-",
        "The column exists but holds nothing for this deal."),
    "Not Found": (
        "Nobody", "Not recoverable", "-",
        "No readable seller file of the deal carries it."),
    "No Seller Tape": (
        "Nobody", "Not recoverable", "-",
        "We own the deal but hold no seller files for it."),
    "Not Relevant": (
        "-", "Not applicable", "-",
        "A legal attribute of another country; it was never expected here."),
}

USABLE = ("Found", "Found in a Table", "Mainly Not Null (90%+)")

BRIDGE_MIN = 0.80    # a tape reaching fewer of the servicer's cases cannot be stitched on
RECON_BAND = 0.10    # collections within +/-10% of the servicer's own report reconcile
FEED_MIN = 0.10      # share of a deal's cases that must pay early before the feed counts

# The attributes that ARE pre-registration payment history, as Section B defines them.
# Everything that measures money moving, or when it moved. Excluded from the median
# count of attributes on page 1b: whether a deal has its payment history is already the
# whole of the full-timeline gate there, so counting the payment columns again inside the
# attribute median would score the same thing twice.
COLLECTION_ATTRIBUTES = (
    "monthly_collection_sum", "monthly_collection_count",
    "collection_months_pre_cut_off", "collection_months_pre_registration",
    "collection_months_post_registration", "total_collections_pre_cut_off",
    "total_collections_post_registration_cat", "total_collections_post_registration_pam",
    "paying_case_count_pre_cut_off", "paying_case_count_pre_registration",
    "paying_case_count_post_registration", "payer_flag", "last_payment_date",
)

PRE_PAYMENT_ATTRIBUTES = (
    "total_collections_pre_cut_off",
    "collection_months_pre_cut_off",
    "collection_months_pre_registration",
    "paying_case_count_pre_cut_off",
    "paying_case_count_pre_registration",
)


def _reason(label: str) -> tuple[str, str, str, str]:
    for prefix, row in REASONS.items():
        if label == prefix or label.startswith(prefix):
            return row
    return ("Unclassified", "-", "-", label)


def _is_usable(label) -> bool:
    return isinstance(label, str) and label.startswith(USABLE)


def _masks(grid: pd.DataFrame, attrs: list[str]) -> tuple[pd.DataFrame, pd.DataFrame]:
    """(relevant, usable) as two deal x attribute boolean frames, aligned on deal_id."""
    block = grid.set_index("deal_id")[[a for a in attrs if a in grid.columns]].astype("string")
    return block.ne("Not Relevant"), block.map(_is_usable)


def _relevance(deal_country: pd.Series, attributes, countries_of) -> pd.DataFrame:
    """deal x attribute: could this attribute apply to this deal at all?

    Read off the attribute's own country list, never off a grid. D2 labels every cell of a
    deal we hold no tape for "No Seller Tape", which overwrites "Not Relevant", so asking
    the tape grid what is relevant counts all 106 attributes for 2,614 deals.
    """
    return pd.DataFrame(
        {a: (deal_country.isin(countries_of[a]) if a in countries_of
             else pd.Series(True, index=deal_country.index))
         for a in attributes},
        index=deal_country.index)


def _feed_pays(pre_collections: pd.DataFrame) -> pd.Series:
    """Per deal, whether the servicer's feed really holds payments from before registration."""
    pc = pre_collections.set_index("deal_id")
    share = pc.cases_paid_before_registration / pc.cases_with_collections.replace(0, pd.NA)
    return (share >= FEED_MIN).fillna(False)


def _correct_pre_payments(use_post: pd.DataFrame, feed_pays: pd.Series) -> pd.DataFrame:
    """Overwrite the feed's claim to pre-registration payment history with the measurement.

    E2/E3 score the pre- and post-registration collection attributes with one fill metric,
    which only asks whether collections exist for the deal at all -- so the grid credits
    the feed with pre-registration payment history on 2,281 deals. Measured against each
    case's own registration date, 2 deals have it. The grid is left as it is, because it
    answers the question it was built for; this column answers a different one, and the
    two pages would otherwise contradict each other on the face of the workbook.
    """
    out = use_post.copy()
    for a in PRE_PAYMENT_ATTRIBUTES:
        if a in out.columns:
            out[a] = out.index.map(lambda d: bool(feed_pays.get(d, False)))
    return out


# --- the deal page -----------------------------------------------------------------

def deal_readiness_frame(deals, d2, e3, quality, in_folder, coverage_pct, in_cat,
                         attributes, pre_collections, countries_of,
                         deal_country, debt_age=None) -> pd.DataFrame:
    """One row per deal: what it clears, how many attributes it has, and the verdict."""
    _, use_pre = _masks(d2, attributes)
    _, raw_post = _masks(e3, attributes)
    feed_pays = _feed_pays(pre_collections)
    use_post = _correct_pre_payments(raw_post, feed_pays)
    relevant = _relevance(deal_country, attributes, countries_of).reindex(use_pre.index)
    # An attribute counts once, from whichever side has it.
    in_scope = relevant.sum(axis=1)
    usable = (use_pre | use_post).sum(axis=1)
    usable_tape, usable_feed = use_pre.sum(axis=1), use_post.sum(axis=1)

    # Pre-registration payment history, the one thing the two sides are not interchangeable
    # on. From the tape it is a column of payments with dates; from the feed it is cases
    # that actually paid before the servicer registered them.
    tape_pays = use_pre[[a for a in PRE_PAYMENT_ATTRIBUTES if a in use_pre.columns]].any(axis=1)

    # The same two counts with every collection column taken out, so page 1b can report
    # "what else do we know about these loans" without re-counting the payment history.
    keep = [c for c in relevant.columns if c not in COLLECTION_ATTRIBUTES]
    in_scope_other = relevant[keep].sum(axis=1)
    found_other = ((use_pre | use_post)[keep] & relevant[keep]).sum(axis=1)

    q = quality.set_index("deal_id")
    folder, cat = set(in_folder), set(in_cat)
    # Years since the borrower defaulted, measured per deal in queries/debt_age.sql.
    # Absent on the deals whose cases carry no default date; blank there, never zero.
    ages = (debt_age.set_index("deal_id").median_debt_age_years
            if debt_age is not None else pd.Series(dtype=float))

    rows = []
    for _, d in deals.iterrows():
        did = d.deal_id
        tape = did in folder
        bridge = coverage_pct.get(did)
        in_raw = did in cat
        recon = bool(q.reconciliation_flag.get(did, False))
        bridged = bridge is not None and bridge >= BRIDGE_MIN
        from_tape, from_feed = bool(tape_pays.get(did, False)), bool(feed_pays.get(did, False))

        pays_pre = from_tape or from_feed
        # Post-registration timeline: the servicer sends a row per loan AND those
        # collections agree with its own report. Everything the full timeline needs,
        # minus the seller's half -- so every full-timeline deal is also one of these.
        post_only = in_raw and recon
        # A full timeline needs all four, and the fourth is the one that bites: a tape
        # that joins is no use without the payments that happened before we bought.
        full = in_raw and recon and tape and bridged and pays_pre

        if not in_raw:
            verdict = "4. Not usable - no servicer data"
        elif not recon:
            verdict = "3. Post-registration, but collections do not reconcile"
        elif full:
            verdict = "1. Full timeline - pre and post, joinable"
        elif tape and bridged:
            verdict = "2. Post-registration; tape joins but carries no earlier payments"
        elif tape:
            verdict = "2. Post-registration; tape held but bridge too weak to join"
        else:
            verdict = "2. Post-registration only - no seller tape"

        rows.append({
            "deal_id": did, "vehicle": d.vehicle, "country": d.country,
            "sector": d.sector, "market": d.market,
            "cases_acquired": d.cases_acquired,
            "balance_eur": d.get("balance_at_acquisition_eur"),
            "debt_age_years": ages.get(did),
            "has_seller_tape": tape, "bridge_coverage": bridge,
            "bridges_80pct": bridged, "in_raw_cat": in_raw,
            "collections_ratio_cat_to_pam": q.collections_ratio_cat_to_pam.get(did),
            "reconciles": recon,
            "has_post_registration_timeline": post_only,
            "has_full_timeline": full,
            "attributes_in_scope": int(in_scope.get(did, 0)),
            "attributes_usable": int(usable.get(did, 0)),
            "attributes_usable_tape": int(usable_tape.get(did, 0)),
            "attributes_usable_feed": int(usable_feed.get(did, 0)),
            "pre_registration_payments": (
                "Yes - Both" if from_tape and from_feed
                else "Yes - Seller Tape" if from_tape
                else "Yes - Servicer Feed" if from_feed else "No"),
            "attributes_in_scope_excl_collections": int(in_scope_other.get(did, 0)),
            "attributes_found_excl_collections": int(found_other.get(did, 0)),
            "verdict": verdict,
        })
    return pd.DataFrame(rows).sort_values(["verdict", "deal_id"]).reset_index(drop=True)


def deal_funnel_frame(readiness: pd.DataFrame) -> pd.DataFrame:
    """The gates, each a strict subset of the one above. Feeds the Summary's headline."""
    n, r = len(readiness), readiness
    stages = [
        ("1. Deals we own", n),
        ("2. The servicer sends loan-by-loan data", int(r.in_raw_cat.sum())),
        ("3. ...and its collections match the servicer's report",
         int((r.in_raw_cat & r.reconciles).sum())),
        ("4. ...and we hold the seller's tape",
         int((r.in_raw_cat & r.reconciles & r.has_seller_tape).sum())),
        (f"5. ...and that tape links to {BRIDGE_MIN:.0%}+ of its loans",
         int((r.in_raw_cat & r.reconciles & r.has_seller_tape & r.bridges_80pct).sum())),
        ("6. ...and it carries payments from before registration (a full timeline)",
         int(r.has_full_timeline.sum())),
    ]
    return pd.DataFrame(stages, columns=["gate", "deals"])


# --- the attribute page ------------------------------------------------------------

def by_attribute_frame(d2, e3, attributes, countries_of, deal_country,
                      pre_collections) -> pd.DataFrame:
    """One row per (country, attribute): on how many of its deals is it usable today?

    A legal attribute belongs to its own countries and gets a row in each, because the
    answer differs between them. A general attribute gets one row, country All, counted
    over every deal.
    """
    _, use_pre = _masks(d2, attributes)
    _, raw_post = _masks(e3, attributes)
    use_post = _correct_pre_payments(raw_post, _feed_pays(pre_collections))
    relevant = _relevance(deal_country, attributes, countries_of).reindex(use_pre.index)
    usable = use_pre | use_post
    post_label, pre_label = e3.set_index("deal_id"), d2.set_index("deal_id")

    def blocking_label(deal, attr):
        """The label of whichever side is actually blocking this deal.

        Normally the servicer feed: that is where the fixable reasons live. But where the
        feed's own label says it has the attribute and we still cannot use it -- the four
        pre-registration payment attributes, corrected above -- the tape is the only route
        left, so its label is the one that explains the gap.
        """
        post = post_label.loc[deal, attr]
        return post if not _is_usable(post) else pre_label.loc[deal, attr]

    rows = []
    for a in attributes:
        for scope in (sorted(countries_of[a]) if a in countries_of else ["All"]):
            deals = (deal_country.index if scope == "All"
                     else deal_country.index[deal_country == scope])
            deals = [d for d in deals if d in usable.index]
            in_scope = [d for d in deals if relevant.loc[d, a]]
            if not in_scope:
                # Norway's two attributes, say: tracked, but we own no deal there. The row
                # stays so the sheet shows nothing is being quietly left out.
                rows.append({"country": scope, "attribute": a, "deals_in_scope": 0,
                             "deals_usable": 0, "deals_usable_tape": 0,
                             "deals_usable_feed": 0, "main_blocker": None,
                             "resolution": "We own no deal in this country"})
                continue
            hit = [d for d in in_scope if usable.loc[d, a]]
            missing = [d for d in in_scope if d not in set(hit)]
            if missing:
                labels = pd.Series([blocking_label(d, a) for d in missing], dtype="string")
                top = labels.value_counts().index[0]
                key = next((p for p in REASONS if top == p or str(top).startswith(p)), top)
                who, needs, how_long, _ = _reason(key)
                blocker = key
                fix = ("Nothing to do - not recoverable" if who == "Nobody"
                       else f"{who}: {needs} ({how_long})")
            else:
                blocker, fix = None, "Already usable everywhere"
            rows.append({
                "country": scope, "attribute": a,
                "deals_in_scope": len(in_scope), "deals_usable": len(hit),
                "deals_usable_tape": int(use_pre.loc[in_scope, a].sum()),
                "deals_usable_feed": int(use_post.loc[in_scope, a].sum()),
                "main_blocker": blocker, "resolution": fix,
            })
    return pd.DataFrame(rows).sort_values(["attribute", "country"]).reset_index(drop=True)


# --- the market view ---------------------------------------------------------------
# A market is one country's one product, as deals_we_own.sql defines it; the sector is
# that product read as bank-like or not. Both arrive on the deal row, so these are a
# regroup of the deal page rather than anything new.

# The two timelines, as sheet 1b splits them. Each gets its own tab so that one page
# carries one gate and one set of shares: a reader never has to ask which denominator a
# percentage in front of them belongs to.
TIMELINES = {
    "post_registration_timeline": (
        "has_post_registration_timeline",
        # The legs still worth showing beside the gate. The reconcile leg is not listed,
        # because the gate column IS the feed and the reconcile legs applied together.
        ("deals_servicer_sends_loan_level_data",),
    ),
    "full_timeline": (
        "has_full_timeline",
        ("deals_with_post_registration_timeline", "deals_we_hold_seller_tape_for",
         "deals_tape_links_to_80pct_of_loans",
         "deals_with_payments_before_registration"),
    ),
}


def by_market_frame(readiness: pd.DataFrame, timeline: str) -> pd.DataFrame:
    """One row per market, for ONE timeline: how much of the market clears it.

    `timeline` is a key of TIMELINES. Every count and every share is out of the market's
    own deals_owned / cases_owned, so the two sheets are directly comparable row for row
    even though each shows only its own gate.
    """
    flag, legs = TIMELINES[timeline]
    r = readiness.dropna(subset=["market"])

    def block(g):
        sub = g[g[flag]]
        deals, cases = len(g), g.cases_acquired.fillna(0).sum()
        bal = g.balance_eur.fillna(0).sum()
        c = sub.cases_acquired.fillna(0).sum()
        b = sub.balance_eur.fillna(0).sum()
        all_legs = {
            "deals_servicer_sends_loan_level_data": int(g.in_raw_cat.sum()),
            "deals_with_post_registration_timeline":
                int(g.has_post_registration_timeline.sum()),
            "deals_we_hold_seller_tape_for": int(g.has_seller_tape.sum()),
            "deals_tape_links_to_80pct_of_loans":
                int((g.has_seller_tape & g.bridges_80pct).sum()),
            "deals_with_payments_before_registration":
                int(g.pre_registration_payments.ne("No").sum()),
        }
        return pd.Series({
            "deals_owned": deals,
            "cases_owned": int(cases),
            "balance_owned_eur": float(bal),
            f"deals_with_{timeline}": len(sub),
            f"cases_with_{timeline}": int(c),
            f"balance_with_{timeline}_eur": float(b),
            f"pct_of_deals_with_{timeline}": len(sub) / deals,
            # Blank, not zero, where Atlas holds no case count for the market at all.
            f"pct_of_cases_with_{timeline}": (c / cases) if cases else None,
            f"pct_of_balance_with_{timeline}": (b / bal) if bal else None,
            # The middle deal's debt age. Deals whose cases carry no default date are
            # left out of the median rather than counted as new debt.
            "median_debt_age_years_all_deals": (
                float(g.debt_age_years.median()) if g.debt_age_years.notna().any() else None),
            f"median_debt_age_years_{timeline}_deals": (
                float(sub.debt_age_years.median()) if sub.debt_age_years.notna().any() else None),
            **{k: all_legs[k] for k in legs},
            # Every deal in a market shares its country, so the scope is one number.
            "other_attributes_in_scope": int(g.attributes_in_scope_excl_collections.max()),
            "median_other_attributes_found_all_deals":
                int(g.attributes_found_excl_collections.median()),
            f"median_other_attributes_found_{timeline}_deals":
                int(sub.attributes_found_excl_collections.median()) if len(sub) else None,
        })

    out = r.groupby(["market", "country", "sector"]).apply(block, include_groups=False)
    out = out.reset_index()
    for c in out.columns:
        if c.startswith(("deals", "cases", "other_attributes",
                         "median_other_attributes_found_all")) and not c.endswith("_eur"):
            out[c] = out[c].astype(int)
    return out.sort_values([f"deals_with_{timeline}", "deals_owned"],
                           ascending=False).reset_index(drop=True)


def by_market_attribute_frame(deals, relevant, use_pre, use_post, attributes,
                              only=None) -> pd.DataFrame:
    """One row per (market, attribute): of the deals in that market it could apply to,
    how many can we use it on today?

    `only` narrows the population to a set of deal ids, which changes what every count
    on the sheet means -- deals_in_scope stops being "deals we own that it applies to"
    and becomes "deals we can model that it applies to". That is why the narrowed view
    is its own tab rather than extra columns here: the denominator moves, so a reader
    comparing a figure across the two would be comparing different questions.
    """
    key = deals.dropna(subset=["market"]).set_index("deal_id")[["market", "country", "sector"]]
    if only is not None:
        key = key.loc[key.index.intersection(pd.Index(list(only)))]
    idx = relevant.index.intersection(key.index)
    key, usable = key.loc[idx], (use_pre | use_post).loc[idx]
    by = [key.market, key.country, key.sector]
    # Atlas holds no case count for the 6 GCB and ORG deals, so they weigh 0 here.
    cases = deals.set_index("deal_id").cases_acquired.reindex(idx).fillna(0)

    def long(frame, name, weight=None):
        block = frame.loc[idx]
        wide = (block if weight is None else block.mul(weight, axis=0)).groupby(by).sum()
        out = wide.stack(future_stack=True).rename(name).reset_index()
        out.columns = ["market", "country", "sector", "attribute", name]
        return out

    out = long(relevant, "deals_in_scope")
    for frame, name, weight in (
            (usable, "deals_usable", None),
            (use_pre.loc[idx], "deals_usable_tape", None),
            (use_post.loc[idx], "deals_usable_feed", None),
            (relevant, "cases_in_scope", cases),
            (usable, "cases_usable", cases)):
        out[name] = long(frame, name, weight)[name].astype(int)
    # An attribute of another country is simply not in scope here; no row for it.
    out = out[out.deals_in_scope > 0]
    # The share beside each count, because a market's size varies by two orders of
    # magnitude and 12 of 12 does not read like 12 of 1,742. The cases share is blank
    # where Atlas holds no case count for the market, rather than a false zero.
    out["deals_usable_pct"] = out.deals_usable / out.deals_in_scope
    out["cases_usable_pct"] = out.cases_usable / out.cases_in_scope.replace(0, pd.NA)
    out = out[["market", "country", "sector", "attribute",
               "deals_in_scope", "deals_usable", "deals_usable_pct",
               "deals_usable_tape", "deals_usable_feed",
               "cases_in_scope", "cases_usable", "cases_usable_pct"]]
    return out.sort_values(["sector", "market", "attribute"]).reset_index(drop=True)


# --- the readiness funnel, per attribute -------------------------------------------
# Not a workbook sheet: this feeds the dashboard's funnel chart, where clicking a gate
# shows what we know about the deals standing at it. It is built from the same masks the
# pages use, so gate 3 reproduces sheet 2b exactly and gate 6 reproduces sheet 2c.

GATES = (
    ("Deals we own", ()),
    ("Servicer sends loan-level data", ("in_raw_cat",)),
    ("Collections reconcile", ("in_raw_cat", "reconciles")),
    ("We hold the seller tape", ("in_raw_cat", "reconciles", "has_seller_tape")),
    ("Tape links to 80% of loans",
     ("in_raw_cat", "reconciles", "has_seller_tape", "bridges_80pct")),
    ("Payments from before registration",
     ("in_raw_cat", "reconciles", "has_seller_tape", "bridges_80pct", "pays_pre")),
)


def _gate_masks(readiness: pd.DataFrame) -> list[tuple[str, pd.Series]]:
    """Each gate as a boolean over the readiness frame, each a subset of the one above."""
    r = readiness.set_index("deal_id")
    flags = {c: r[c].astype(bool) for c in
             ("in_raw_cat", "reconciles", "has_seller_tape", "bridges_80pct")}
    flags["pays_pre"] = r.pre_registration_payments.ne("No")
    out, keep = [], pd.Series(True, index=r.index)
    for name, needs in GATES:
        m = pd.Series(True, index=r.index)
        for f in needs:
            m &= flags[f]
        out.append((name, m))
    return out


# Where an attribute can come from. Asked for on the dashboard 2026-11-04 so the
# attribute tables can be colour-coded by source.
#   Case data        the servicer sends it per case, or our warehouse carries it per case
#   Portfolio data   it exists only per batch or portfolio, so it cannot be split to a loan
#   Seller tape only neither side carries it; the seller's diligence file is the only source
def attribute_source(attr: str) -> str:
    import post_registration_map as prmap
    if prmap.raw_feed(attr) or prmap.npl_grain(attr) in ("case", "collections"):
        return "Case data"
    if prmap.npl_grain(attr) in ("batch", "pam"):
        return "Portfolio data"
    return "Seller tape only"


def gate_market_frame(readiness: pd.DataFrame) -> pd.DataFrame:
    """The same six gates, per market, so the funnel can be filtered to one.

    Shares are out of the MARKET's own deals, cases and balance, not the book's, so a
    market's row reads the same way the book's does.
    """
    r = readiness.dropna(subset=["market"]).set_index("deal_id")
    rows = []
    for market, g in r.groupby("market"):
        cases, bal = g.cases_acquired.fillna(0), g.balance_eur.fillna(0)
        td, tc, tb = len(g), float(cases.sum()), float(bal.sum())
        for step, (name, mask) in enumerate(_gate_masks(g.reset_index()), start=1):
            m = mask.reindex(g.index).fillna(False)
            c, b = float(cases[m].sum()), float(bal[m].sum())
            rows.append({
                "market": market, "step": step, "stage": name,
                "deals": int(m.sum()),
                "pct_deals": float(m.sum() / td) if td else None,
                "cases": int(c), "pct_cases": (c / tc) if tc else None,
                "balance_eur": b, "pct_balance": (b / tb) if tb else None,
                "median_debt_age_years": (float(g.loc[m, "debt_age_years"].median())
                                          if g.loc[m, "debt_age_years"].notna().any() else None),
                "median_attributes": (int(g.loc[m, "attributes_found_excl_collections"].median())
                                      if m.any() else None),
            })
    return pd.DataFrame(rows)


def gate_frames(readiness, relevant, use_pre, use_post, attributes):
    """(stages, per-attribute rows) for the dashboard's funnel.

    stages: one row per gate with deals, cases and the median attribute count.
    rows:   one row per (gate, attribute), the same counts sheets 2b and 2c carry.
    """
    r = readiness.set_index("deal_id")
    cases = r.cases_acquired.fillna(0)
    bal = r.balance_eur.fillna(0)
    usable = (use_pre | use_post)
    total_d, total_c, total_b = len(r), float(cases.sum()), float(bal.sum())

    stages, rows = [], []
    for step, (name, mask) in enumerate(_gate_masks(readiness), start=1):
        ids = [d for d in r.index[mask] if d in relevant.index]
        c, b = float(cases[mask].sum()), float(bal[mask].sum())
        stages.append({
            "step": step, "stage": name,
            "deals": int(mask.sum()),
            "pct_deals": float(mask.sum() / total_d) if total_d else None,
            "cases": int(c),
            "pct_cases": (c / total_c) if total_c else None,
            "balance_eur": b,
            "pct_balance": (b / total_b) if total_b else None,
            "median_debt_age_years": (float(r.loc[mask, "debt_age_years"].median())
                                      if r.loc[mask, "debt_age_years"].notna().any() else None),
            "median_attributes": int(r.loc[mask, "attributes_found_excl_collections"].median())
                                 if mask.any() else None,
            "endpoint": "r" if step == 3 else "f" if step == 6 else None,
        })
        rel, use = relevant.loc[ids], usable.loc[ids]
        pre, post = use_pre.loc[ids], use_post.loc[ids]
        w = cases.reindex(ids).fillna(0)
        for a in attributes:
            if a not in rel.columns:
                continue
            in_scope = rel[a]
            if not in_scope.any():
                continue
            hit = in_scope & use[a]
            rows.append({
                "step": step, "stage": name, "attribute": a,
                "source": attribute_source(a),
                "deals_in_scope": int(in_scope.sum()),
                "deals_usable": int(hit.sum()),
                "deals_usable_tape": int((in_scope & pre[a]).sum()),
                "deals_usable_feed": int((in_scope & post[a]).sum()),
                "cases_in_scope": int(w[in_scope].sum()),
                "cases_usable": int(w[hit].sum()),
            })
    return pd.DataFrame(stages), pd.DataFrame(rows)


# --- the sheets --------------------------------------------------------------------

def all_sheets(deals, d2, e3, quality, in_folder, coverage_pct, in_cat, attributes,
               countries_of, deal_country, pre_collections, debt_age=None) -> list[Sheet]:
    readiness = deal_readiness_frame(deals, d2, e3, quality, in_folder, coverage_pct,
                                     in_cat, attributes, pre_collections, countries_of,
                                     deal_country, debt_age)
    by_attr = by_attribute_frame(d2, e3, attributes, countries_of, deal_country,
                                 pre_collections)
    _, use_pre = _masks(d2, attributes)
    _, raw_post = _masks(e3, attributes)
    use_post = _correct_pre_payments(raw_post, _feed_pays(pre_collections))
    relevant = _relevance(deal_country, attributes, countries_of).reindex(use_pre.index)
    by_market_r = by_market_frame(readiness, "post_registration_timeline")
    by_market_f = by_market_frame(readiness, "full_timeline")
    # One attribute sheet per timeline, each over that timeline's own deals. There is no
    # whole-book version: a denominator of "every deal we own" includes the 1,631 deals
    # nothing can be modelled on, which flatters nothing and answers no question anyone
    # asked. Sheet 2a still carries the per-country view over the whole book.
    deals_r = set(readiness.loc[readiness.has_post_registration_timeline, "deal_id"])
    deals_f = set(readiness.loc[readiness.has_full_timeline, "deal_id"])
    by_market_attr_r = by_market_attribute_frame(deals, relevant, use_pre, use_post,
                                                 attributes, only=deals_r)
    by_market_attr_f = by_market_attribute_frame(deals, relevant, use_pre, use_post,
                                                 attributes, only=deals_f)
    ratio = "A decimal: 0.098 = 9.8%."
    sector = ("Financial Services is everything bank-like, where the debt began as credit. "
              "Non-Financial Services is everything else, where it began as an unpaid bill; "
              "insurance sits here, since the claim is an unpaid premium. Unclassified is "
              "PAM's own catch-all product 'Other', 745 deals, plus the 12 deals PAM never "
              "reported.")
    market = ("One country's one sector: SE - Financial Services. 39 of them, defined in queries/deals_we_own.sql so every page agrees.")
    pages = [
        Sheet("1a Deal Readiness", "1a - Every deal, and what it is good for",
              "Deal by deal: what it clears, how many attributes we can use on it, and "
              "whether we have its payment history from before registration.",
              "One row per deal.",
              "The grids D2 and E3 of this workbook, plus queries/pre_registration_collections.sql.",
              readiness, {
                  "deal_id": "VEHICLE-ID.",
                  "vehicle": "HEI Heimdall, LOK Lokki, LEG legacy, GCB, ORG.",
                  "country": "The deal's country.",
                  "sector": sector,
                  "market": market,
                  "cases_acquired": "Cases bought, where known.",
                  "balance_eur": "Balance bought, in EUR at the latest month-end rate. 2,668 of 2,674 deals report it as principal; 4 report GBV, which includes interest and fees.",
                  "debt_age_years": "Years from the borrower's default to today, per queries/debt_age.sql. The middle case of the deal. A quarter of cases carry no default date and are left out rather than counted as new debt; 291 deals have none at all and are blank. This is the age of the DEBT, not how long we have held it.",
                  "has_seller_tape": "We hold seller files for it.",
                  "bridge_coverage": "Share of the servicer's cases the tape reaches. Empty where there is no bridge. " + ratio,
                  "bridges_80pct": f"bridge_coverage >= {BRIDGE_MIN:.0%}, the threshold for joining the two halves.",
                  "in_raw_cat": "The servicer sends loan-by-loan data for it.",
                  "collections_ratio_cat_to_pam": "Our collections / the servicer's own report, over the months both cover.",
                  "reconciles": f"Months ratio >= 0.8 AND collections within +/-{RECON_BAND:.0%}.",
                  "attributes_in_scope": "Attributes that could apply to this deal. Excludes other countries' legal attributes.",
                  "attributes_usable": "Of those, how many we have and have filled, FROM EITHER SIDE. The headline: it does not matter which side carries it.",
                  "attributes_usable_tape": "Of attributes_usable, how many the seller's tape carries. Overlaps the next column.",
                  "attributes_usable_feed": "Of attributes_usable, how many the servicer's feed carries. Overlaps the previous column.",
                  "pre_registration_payments": "Do we have payment history from before registration? Seller Tape = the tape carries dated payments. Servicer Feed = at least "
                                               f"{FEED_MIN:.0%} of the deal's cases paid before the servicer registered them, which only 2 deals do. Understates before 2014, where the collections feed starts.",
                  "has_post_registration_timeline": "The servicer sends a row per loan AND those collections reconcile to its own report. The loan's life from the day we bought it.",
                  "has_full_timeline": "Seller tape, bridged to 80%+ of the loans, payments from before registration, and post-registration collections that reconcile. All four.",
                  "attributes_in_scope_excl_collections": "attributes_in_scope less the 13 collection columns, which the full-timeline gate already covers.",
                  "attributes_found_excl_collections": "attributes_usable less the same 13. What page 1b takes its median of.",
                  "verdict": "1 full timeline, 2 post-registration only, 3 post but unreconciled, 4 not usable.",
              }, money=("balance_eur",),
              decimals=("bridge_coverage", "collections_ratio_cat_to_pam", "debt_age_years"),
              wide=("verdict", "pre_registration_payments")),
        Sheet("2a By Attribute", "2a - Every attribute, and how much of the book we have it on",
              "For each attribute, on how many of the deals it could apply to we can "
              "actually use it today, counting either side.",
              "One row per (country, attribute). A legal attribute repeats per country; a "
              "general one appears once, as All.",
              "The grids D2 and E3 of this workbook.",
              by_attr, {
                  "country": "The country the attribute belongs to, or All for a general one.",
                  "attribute": "The attribute, as Sections A and B name it.",
                  "deals_in_scope": "Deals it could apply to. The denominator, in deals.",
                  "deals_usable": "Of those, how many we have it on and filled, FROM EITHER SIDE.",
                  "deals_usable_tape": "Of deals_in_scope, how many have it in the seller's tape. Overlaps the next column.",
                  "deals_usable_feed": "Of deals_in_scope, how many have it in the servicer's feed. Overlaps the previous column. For the four pre-registration payment attributes this is the measured count, not the grid's: E3 scores those with a metric that only asks whether collections exist at all.",
                  "main_blocker": "On the deals where neither side has it, the commonest reason.",
                  "resolution": "Who would have to do what, and roughly how long. Our judgement, not a commitment.",
              }, wide=("main_blocker", "resolution")),
        Sheet("1b By Market (R)", "1b - Every market: the post-Registration timeline",
              "For each market, how many of its deals we can follow from the day we "
              "bought them: the servicer sends a row per loan, and those collections "
              "reconcile to its own report.",
              "One row per market, most post-registration deals first.",
              "Sheet 1a, regrouped. Nothing new.",
              by_market_r, {
                  "market": market,
                  "country": "The market's country, split out so the sheet can be filtered by it.",
                  "sector": sector,
                  "deals_owned": "Deals we own in this market. The denominator for every share on this row, here and on sheet 1b (F), so the two sheets compare row for row.",
                  "cases_owned": "Cases bought across them. Atlas holds no case count for the 6 GCB and ORG deals, which therefore add nothing.",
                  "balance_owned_eur": "Balance bought, in EUR at the latest month-end rate. 2,668 of 2,674 deals report it as principal; 4 report GBV, which includes interest and fees.",
                  "deals_with_post_registration_timeline": "Deals clearing BOTH legs: the servicer sends loan-level data, and those collections reconcile. We can follow these from the day we bought them, but not before. Sheet 1b (F) asks how many go further back.",
                  "cases_with_post_registration_timeline": "Cases bought across those deals.",
                  "balance_with_post_registration_timeline_eur": "Balance bought across those deals, in EUR.",
                  "pct_of_deals_with_post_registration_timeline": "deals_with_post_registration_timeline / deals_owned.",
                  "pct_of_cases_with_post_registration_timeline": "cases_with_post_registration_timeline / cases_owned. Blank where the market has no case count at all.",
                  "pct_of_balance_with_post_registration_timeline": "balance_with_post_registration_timeline_eur / balance_owned_eur. The share of the money, which is what pricing cares about.",
                  "median_debt_age_years_all_deals": "Years from the borrower's default to today, per queries/debt_age.sql. The middle deal of the market. A quarter of cases carry no default date and are left out rather than counted as new debt; 291 deals have none at all and are blank. This is the age of the DEBT, not how long we have held it.",
                  "median_debt_age_years_post_registration_timeline_deals": "The same, over the post-registration deals only.",
                  "deals_servicer_sends_loan_level_data": "The first leg on its own: deals Intrum sends a row per loan for, rather than a batch total. The gap between this and the gate column is deals whose collections do not reconcile.",
                  "other_attributes_in_scope": "How many non-payment attributes could apply to a deal here. One number per market, since a market is one country. Excludes the 13 collection columns, which the timeline gate already covers.",
                  "median_other_attributes_found_all_deals": "The middle deal in this market, counting non-payment attributes we hold and have filled, from either side.",
                  "median_other_attributes_found_post_registration_timeline_deals": "The same, over the post-registration deals only. Blank where the market has none.",
              }, wide=("market",),
              money=("balance_owned_eur", "balance_with_post_registration_timeline_eur"),
              decimals=("median_debt_age_years_all_deals",
                        "median_debt_age_years_post_registration_timeline_deals"),
              percent=("pct_of_deals_with_post_registration_timeline",
                       "pct_of_cases_with_post_registration_timeline",
                       "pct_of_balance_with_post_registration_timeline")),
        Sheet("1b By Market (F)", "1b - Every market: the Full timeline",
              "For each market, how many of its deals we can follow from origination: "
              "everything the post-registration timeline needs, plus the seller's tape, "
              "bridged to the servicer's cases, carrying payments from before we bought.",
              "One row per market, most full-timeline deals first.",
              "Sheet 1a, regrouped. Nothing new.",
              by_market_f, {
                  "market": market,
                  "country": "The market's country, split out so the sheet can be filtered by it.",
                  "sector": sector,
                  "deals_owned": "Deals we own in this market. The same denominator as on sheet 1b (R), so the two sheets compare row for row.",
                  "cases_owned": "Cases bought across them. Atlas holds no case count for the 6 GCB and ORG deals, which therefore add nothing.",
                  "balance_owned_eur": "Balance bought, in EUR at the latest month-end rate. 2,668 of 2,674 deals report it as principal; 4 report GBV, which includes interest and fees.",
                  "deals_with_full_timeline": "Deals clearing ALL FOUR legs to the right. We can follow these from origination to today. A strict subset of the post-registration deals on sheet 1b (R). Only 8 deals in the whole book, so read the counts here, not the shares.",
                  "cases_with_full_timeline": "Cases bought across those deals.",
                  "balance_with_full_timeline_eur": "Balance bought across those deals, in EUR.",
                  "pct_of_deals_with_full_timeline": "deals_with_full_timeline / deals_owned.",
                  "pct_of_cases_with_full_timeline": "cases_with_full_timeline / cases_owned. Blank where the market has no case count at all.",
                  "pct_of_balance_with_full_timeline": "balance_with_full_timeline_eur / balance_owned_eur. The share of the money, which is what pricing cares about.",
                  "median_debt_age_years_all_deals": "Years from the borrower's default to today, per queries/debt_age.sql. The middle deal of the market. A quarter of cases carry no default date and are left out rather than counted as new debt; 291 deals have none at all and are blank. This is the age of the DEBT, not how long we have held it.",
                  "median_debt_age_years_full_timeline_deals": "The same, over the full-timeline deals only.",
                  "deals_with_post_registration_timeline": "Leg 1, the prerequisite: loan-level data that reconciles. Sheet 1b (R) breaks this one down.",
                  "deals_we_hold_seller_tape_for": "Leg 2: deals we hold the seller's diligence files for. The only source of anything from before we bought.",
                  "deals_tape_links_to_80pct_of_loans": f"Leg 3: of those, deals where the tape's loan ids reach {BRIDGE_MIN:.0%} or more of the servicer's cases, so the two halves join into one series.",
                  "deals_with_payments_before_registration": "Leg 4: deals with dated payments from before the servicer registered the case, from either side. Almost always the tape: measured 2026-11-03, the servicer's feed carries them on 2 deals. This is the leg that fails most often.",
                  "other_attributes_in_scope": "How many non-payment attributes could apply to a deal here. One number per market, since a market is one country. Excludes the 13 collection columns, which the timeline gate already covers.",
                  "median_other_attributes_found_all_deals": "The middle deal in this market, counting non-payment attributes we hold and have filled, from either side.",
                  "median_other_attributes_found_full_timeline_deals": "The same, over the full-timeline deals only. Blank where the market has none, which is most markets.",
              }, wide=("market",),
              money=("balance_owned_eur", "balance_with_full_timeline_eur"),
              decimals=("median_debt_age_years_all_deals",
                        "median_debt_age_years_full_timeline_deals"),
              percent=("pct_of_deals_with_full_timeline",
                       "pct_of_cases_with_full_timeline",
                       "pct_of_balance_with_full_timeline")),
        Sheet("2b By Market and Attribute (R)",
              "2b - Every attribute, on the post-Registration deals",
              "Of the deals we can follow from the day we bought them, how many carry "
              "each attribute?",
              "One row per (market, attribute), over the 1,043 post-registration deals.",
              "Sheets 1a and 2a, regrouped. Nothing new.",
              by_market_attr_r, {
                  "market": market,
                  "country": "The market's country, split out so the sheet can be filtered by it.",
                  "sector": sector,
                  "attribute": "The attribute, as Sections A and B name it.",
                  "deals_in_scope": "Deals in this market WITH A POST-REGISTRATION TIMELINE that the attribute could apply to. The denominator, in deals. It is NOT every deal we own, so a figure here is not comparable with sheet 2a.",
                  "deals_usable": "Of those, how many we have it on and filled, FROM EITHER SIDE.",
                  "deals_usable_pct": "deals_usable as a share of deals_in_scope, so markets of different sizes compare.",
                  "deals_usable_tape": "Of deals_in_scope, how many have it in the seller's tape. Overlaps the next column.",
                  "deals_usable_feed": "Of deals_in_scope, how many have it in the servicer's feed. Overlaps the previous column.",
                  "cases_in_scope": "Cases bought across the deals in scope. The same denominator weighted by size.",
                  "cases_usable": "Cases bought across the deals we can use it on.",
                  "cases_usable_pct": "cases_usable as a share of cases_in_scope. Blank where the market has no case count.",
              }, wide=("market",), percent=("deals_usable_pct", "cases_usable_pct")),
        Sheet("2c By Market and Attribute (F)",
              "2c - Every attribute, on the Full-timeline deals",
              "Of the deals we can follow from origination, how many carry each "
              "attribute? WARNING: 8 deals in the whole book. Read the counts, not the "
              "shares - every denominator here is in single figures.",
              "One row per (market, attribute), over the 8 full-timeline deals.",
              "Sheets 1a and 2a, regrouped. Nothing new.",
              by_market_attr_f, {
                  "market": market,
                  "country": "The market's country, split out so the sheet can be filtered by it.",
                  "sector": sector,
                  "attribute": "The attribute, as Sections A and B name it.",
                  "deals_in_scope": "Deals in this market WITH A FULL TIMELINE that the attribute could apply to. Single figures everywhere: the whole book has 8 such deals, in a handful of markets.",
                  "deals_usable": "Of those, how many we have it on and filled, FROM EITHER SIDE.",
                  "deals_usable_pct": "deals_usable as a share of deals_in_scope. On this sheet that is a share of at most a few deals, so it moves in big steps and should not be quoted on its own.",
                  "deals_usable_tape": "Of deals_in_scope, how many have it in the seller's tape. Overlaps the next column. High here by construction: a full timeline requires a tape.",
                  "deals_usable_feed": "Of deals_in_scope, how many have it in the servicer's feed. Overlaps the previous column.",
                  "cases_in_scope": "Cases bought across the deals in scope. The same denominator weighted by size.",
                  "cases_usable": "Cases bought across the deals we can use it on.",
                  "cases_usable_pct": "cases_usable as a share of cases_in_scope. Blank where the market has no case count.",
              }, wide=("market",), percent=("deals_usable_pct", "cases_usable_pct")),
    ]
    # Deals, then the same by market on each timeline; attributes, then the same.
    return [pages[0], pages[2], pages[3], pages[1], pages[4], pages[5]]
