# Before and after the hackathon-test fixes

Measured 2026-11-23 from live queries:

- **Before:** prod `NPL_COMMON` today (`prod.sql`, connection `brocc_prod_sso`).
- **After:** the sandbox build of the `hackathon-test` branch in `DEV.HACKATHON` (`hackathon.sql`,
  connection `dev`), built 2026-11-23 with the whole Swedish history.

CAT is the payments we add up from Intrum's loan-level feed (`fct_case_collection`). PAM is Intrum's
own monthly report of what each deal collected (`fct_portfolio_snapshot_monthly`). Both run from the
purchase month to PAM's last month (Oct 2026).

## Five key deals

PAM is the same in both columns (Intrum's report doesn't change); only CAT moves.
PAM here is `gross_cash_recoveries`, as in each deal's `summary.md`; the 639-deal reconciliation below uses the
unlevelled figure, so a few deals read slightly differently there (LOK-SE25013: 81.1% here, 81.9% below).

| Deal (Intrum id) | Source | Before (SEK) | After (SEK) | Before vs PAM | After vs PAM | Paying cases before → after |
|---|---|---:|---:|---:|---:|---:|
| **HEI-SE17039** (SE17039) | PAM | 141,558,830.74 | 141,558,830.74 | | | |
| | CAT, all | 68,580,992.07 | 132,982,439.08 | 48.4% | **93.9%** | 785 → 1,847 |
| | ↳ system 1062 | 0 | 67,019,454.73 | | | 0 → 1,061 |
| | ↳ system 2080 | 68,580,992.07 | 65,962,984.35 | | | 785 → 786 |
| **HEI-SE19026** (SE19026) | PAM | 145,389,472.47 | 145,389,472.47 | | | |
| | CAT, all | 132,861,380.57 | 141,336,657.86 | 91.4% | **97.2%** | 5,923 → 6,678 |
| | ↳ system 1062 | 0 | 8,475,277.29 | | | 0 → 755 |
| | ↳ system 2080 | 132,861,380.57 | 132,861,380.57 | | | 5,923 → 5,923 |
| **HEI-SE20009** (SE20009) | PAM | 286,382,971.75 | 286,382,971.75 | | | |
| | CAT, all | 279,586,566.09 | 280,130,516.90 | 97.6% | **97.8%** | 10,078 → 10,087 |
| **LOK-SE25008** (SE25018) | PAM | 46,777,512.67 | 46,777,512.67 | | | |
| | CAT, all | 3,511,618.92 | 45,817,409.67 | 7.5% | **97.9%** | 566 → 5,122 |
| | ↳ system 1062 | 0 | 42,305,450.75 | | | 0 → 4,556 |
| | ↳ system 2080 | 3,511,618.92 | 3,511,958.92 | | | 566 → 566 |
| **LOK-SE25013** (SE25037) | PAM | 23,339,279.20 | 23,339,279.20 | | | |
| | CAT, all | 13,238,233.84 | 18,921,905.83 | 56.7% | **81.1%** | 995 → 1,296 |
| | ↳ system 1062 | 0 | 5,683,671.99 | | | 0 → 301 |
| | ↳ system 2080 | 13,238,233.84 | 13,238,233.84 | | | 995 → 995 |

- **Bug 1 (1062 dropped)** was most of the gap on four of the five deals: 1062 went from nothing to
  SEK 67.0m on HEI-SE17039, 42.3m on LOK-SE25008, 8.5m on HEI-SE19026 and 5.7m on LOK-SE25013.
- **The April 2019 re-booking** only touches HEI-SE17039 here (2080 down SEK 2.6m); the other
  four were bought after it.
- **HEI-SE20009** barely moves: bought July 2020, no 1062 cases.
- **LOK-SE25013 is still short (81.1%)**, and not because of our model: every raw CAT payment on its
  cases reaches `fct_case_collection`. The gap sits in its first five months (Dec 2025 - Apr 2026:
  CAT SEK 9.3m vs PAM 13.0m); from May 2026 CAT is 95% of PAM. CAT has fewer payments than PAM
  while the book was being loaded (`se25037_onboarding_gap.sql`). A question for Intrum.

## All 639 Swedish deals

A deal reconciles when CAT is within 10% of PAM and has payments in at least 80% of PAM's months
(`../intrum_clarifications/queries/3_reconcile_hackathon_build.sql`).

| | Deals |
|---|---:|
| Reconcile before (prod, 18 Nov workbook) | 53 |
| Reconcile after (this build) | **82** |
| Newly reconciling | 43 |
| Reconciled before, not now | 14 |

CAT as a share of PAM after the fixes:

| CAT vs PAM | Deals |
|---|---:|
| No CAT or no PAM | 108 |
| Under 50% | 174 |
| 50–90% | 267 |
| 90–110% | 89 |
| Over 110% | 1 |

Deals that reconcile, by purchase year:

| Bought | Reconcile | Deals |
|---|---:|---:|
| 2014 or earlier | 24 | 519 |
| 2015–2019 | 36 | 82 |
| 2020 or later | 22 | 38 |

## What this tells us

- **Solid:** CAT no longer runs above PAM: one deal is over 110%, against many before. Both bugs
  that made it too high (1062 dropped, then 2080 double-counted) are gone.
- **Solid:** the four seller-tape deals that matter most now reconcile: HEI-SE17039 (93.9%),
  HEI-SE19026 (97.2%), HEI-SE20009 (97.8%) and LOK-SE25008 (97.3%, was 7.5%). HEI-SE15044 (98.3%) and
  HEI-SE16025 (96.1%) also reconcile now; their "pre-2020 gap" was our double count.
- **Open:** most deals left are CAT *below* PAM, and most were bought in 2014 or earlier. That
  fits Intrum moving Sweden onto CAT in October 2014: older payments were never in CAT. This is
  the question to Intrum about history before Oct 2014.
- **Open:** LOK-SE25013 (81.9%) and LOK-SE25014 (85.5%) are still short of PAM, with payments in
  every month.
- **Lower than the earlier estimate of 115:** that estimate came from a raw rebuild that still
  double-counted the April 2019 re-booking, so some deals only looked close to PAM.

## Why the other 557 don't reconcile

Most deals were bought before Intrum moved Sweden onto CAT in October 2014, so CAT has none of
their earlier payments while PAM does. Counting every deal from November 2014 (its first full month
on CAT) instead of from purchase, **331 of 639 reconcile**, and the deals bought before Oct 2014 sit
at a median of 95.5% of PAM.

Each of the 557 failing deals counted once:

One-off / forward flow is Intrum's own `deal_type` on the batch (`Ongoing` = forward flow; a deal with
any ongoing batch counts as forward flow, 3 deals have both). Atlas can't split them: it holds all
Heimdall books as one deal. Forward flows reconcile far more often: 33 of 61 (54%), against 49 of 578
one-off deals (8%), largely because most one-off deals were bought before CAT's history starts.
Cases are cases in the hackathon build. Payment months are the first and last month with payments
after purchase, up to Oct 2026 (the last complete month).

| Why a deal doesn't reconcile (counted from purchase) | Deals | One-off / forward flow | Cases | Bought | CAT payments | PAM payments | Can we fix it? | What we can do |
|---|---:|---:|---:|---|---|---|---|---|
| Bought before Oct 2014; matches PAM from Nov 2014 on | 249 | 238 / 11 | 679,646 | Dec 2001 – Aug 2014 | Jan 2003 – Oct 2026 | Dec 2001 – Oct 2026 | No: CAT holds only part of the payments before Oct 2014 | Use these deals from Nov 2014 on (they reconcile then). Ask Intrum for pre-2014 payment history (question 5) |
| Bought before Oct 2014; still below 90% from Nov 2014 | 120 | 118 / 2 | 73,305 | Oct 2001 – Aug 2014 | Apr 2002 – Oct 2026 | Oct 2001 – Oct 2026 | Not yet known | Check year by year: if only the first years are short it is the onboarding gap; if every year is short, list the deals for Intrum |
| No cases in CAT (bought 2001–2010) | 83 | 83 / 0 | 0 | Oct 2001 – Aug 2010 | none | Oct 2001 – Mar 2020 | No | Leave out of loan-level work. Ask Intrum whether they were closed before CAT or serviced elsewhere (question 4) |
| Bought after Oct 2014; CAT below 90% | 65 | 50 / 15 | 489,719 | Nov 2014 – Dec 2025 | Nov 2014 – Oct 2026 | Nov 2014 – Oct 2026 | Not yet known | Biggest group by cases. Same year-by-year check; start with the worst (HEI-SE20018 at 16%, HEI-SE20016 at 22%, HEI-SE17041 at 47%) |
| No CAT payments, but the deal has cases | 23 | 23 / 0 | 41 | Jun 2002 – May 2011 | none | Jun 2002 – Nov 2023 | Not yet known | Tiny books. Check whether raw CAT has payments on these cases; if it does, the model loses them and it is ours to fix |
| CAT above 110% | 8 | 8 / 0 | 53 | Oct 2007 – Feb 2010 | Feb 2014 – Oct 2026 | Nov 2007 – Oct 2026 | Maybe | Tiny books. Look for duplicates the re-booking rule misses (e.g. rows that differ in one empty column) |
| Within 10% but CAT missing months | 6 | 6 / 0 | 75 | Mar 2007 – Jun 2021 | Aug 2011 – Aug 2026 | Mar 2007 – Aug 2026 | Mostly no | Usable for curves; list the months PAM has and CAT doesn't for Intrum (question 7) |
| No PAM in the window | 3 | 3 / 0 | 5 | Apr 2007 – May 2009 | Mar 2014 – Jun 2014 | Apr 2007 – Jun 2014 | No | Nothing to compare against; leave out of the reconciled set |
| **Total not reconciling** | **557** | **529 / 28** | **1,242,844** | | | | | |
| Reconcile (from purchase) | 82 | 49 / 33 | 671,883 | Jan 2007 – Jun 2025 | May 2012 – Oct 2026 | Nov 2007 – Oct 2026 | | Use for loan-level work now |
| **All Swedish deals** | **639** | **578 / 61** | **1,914,727** | | | | | |

The figure to quote is **82 reconcile from purchase, 331 from Nov 2014**. Next to explain are the 185
deals where CAT is short of PAM even after Nov 2014. On LOK-SE25013 the shortfall is the first months
after onboarding (CAT has fewer payments than PAM while the book was loaded, and our model loses none);
the year-by-year check shows how many of the 185 are the same.

## The same, by market and deal type

Market is the sector of Intrum's product on the batch (`original_product_name`). The group names match
`work/workshop/queries/deals_seen_by_market.sql`, but that query buckets by seller from Atlas, so the two don't mix:
FS = Finance, Bank Loan, Credit Card; Non-FS = Telecom, Fixed Telephone, Utility, Mail Order, Retail sale;
Unknown = Other (337 deals), Real Estate, Published, Transport, Insurance, or batches that disagree. FF = forward
flow. Built by `deal_reasons.sql` and `reasons_by_market.py` (sandbox, 24 Nov 2026).

| Why it doesn't reconcile | FS one-off | Non-FS one-off | Unknown one-off | FS FF | Non-FS FF | Unknown FF | All |
|---|---:|---:|---:|---:|---:|---:|---:|
| Bought before Oct 2014; matches PAM from Nov 2014 on | 61 | 55 | 122 | 3 | 4 | 4 | 249 |
| Bought before Oct 2014; still below 90% from Nov 2014 | 15 | 26 | 77 | 2 | 0 | 0 | 120 |
| No cases in CAT (bought 2001-2010) | 6 | 1 | 77 | 0 | 0 | 0 | 84 |
| Bought after Oct 2014; CAT below 90% | 7 | 22 | 21 | 3 | 8 | 4 | 65 |
| No CAT payments, though the deal has cases | 0 | 0 | 24 | 0 | 0 | 0 | 24 |
| CAT above 110% | 0 | 0 | 8 | 0 | 0 | 0 | 8 |
| Within 10%, but CAT missing some months | 0 | 0 | 6 | 0 | 0 | 0 | 6 |
| No PAM in the window | 0 | 0 | 1 | 0 | 0 | 0 | 1 |
| **Total not reconciling** | **89** | **104** | **336** | **8** | **12** | **8** | **557** |
| Reconcile from purchase | 18 | 10 | 21 | 21 | 11 | 1 | 82 |
| **All Swedish deals** | **107** | **114** | **357** | **29** | **23** | **9** | **639** |

Solid: the large groups and the one-off / forward-flow split match the table above exactly. Shaky: 2 of the 639
deals land in a different small group (No cases 84 not 83, No CAT payments 24 not 23, No PAM 1 not 3); the rule
used for the table above wasn't saved, and these two edge cases can't be told apart from it. Unknown is the
largest market because Intrum labels most older books "Other".

## The 14 deals that reconciled before but not now

They passed before only because duplicates pushed CAT up (5 were already flagged as "only passes
because our bugs cancel out"). With the duplicates gone they sit at 81-90% of PAM.

| Group | Deals | What's going on |
|---|---:|---|
| Bought before Oct 2014 | 6 | Reconcile again counted from Nov 2014: only old history is missing |
| First year short, then fine | 3 (HEI-SE14011, HEI-SE14059, HEI-SE17012) | Their first year after purchase is 16-38% of PAM; later years 86-100%. Same onboarding gap as LOK-SE25013 |
| Short in every period | 5 (HEI-SE14023, HEI-SE14040, HEI-SE14058, HEI-SE17020, HEI-SE17040) | 78-91% of PAM, 2020 onwards too; not explained yet |

The re-booking rule was checked on the three "first year short" deals: their middle years go from
118-164% of PAM without it to 86-100% with it, so it removes duplicates, not real payments.

## Data quality

- 10,911 payment rows in the build are dated in the current month or later, including placeholders
  such as 2099-12-30. All the queries here stop at the last complete month, so these are left out
  of every figure above, not corrected.
- `prod.sql` counts months as distinct months. The original `../individual_deal_dataset/HEI-SE17039/summary/summary_sources.sql`
  counts batch-months, which overstates months on deals with several batches (SE20009 read 152).
