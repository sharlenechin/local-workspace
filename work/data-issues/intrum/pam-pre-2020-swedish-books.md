# PAM reports less 2016–2019 cash than CAT on the two oldest Swedish books

**For:** Intrum, via whoever owns the PAM batch report
**Scope:** SE15044 (Dec 2015) and SE16025 (2016), measured against SE19026 and SE20009 as controls
**Measured:** 2026-11-02, read-only, from `PROD_RAW.HYPERION_INTRUM_CAT` and `PROD_RAW.HYPERION_INTRUM_PAM`

## The finding

Loan-level CAT and batch-level PAM agree closely on recent cash and diverge sharply on
old cash. The break is the same year on both books.

| year | SE15044 CAT / PAM | SE16025 CAT / PAM |
|---|---|---|
| 2016 | 151% | 136% |
| 2017 | 166% | 163% |
| 2018 | **180%** | **180%** |
| 2019 | 121% | 123% |
| 2020 | 98.5% | 99.8% |
| 2021 | 99.9% | 100.6% |
| 2022 | 99.6% | 100.3% |
| 2023 | 98.7% | 101.6% |
| 2024 | 100.2% | 104.7% |
| 2025 | 99.2% | 102.8% |

Those four early years hold 54.9m of SE15044's 53.7m lifetime gap and 22.3m of
SE16025's 22.7m. After 2019 there is effectively nothing left to explain.

SE19026 and SE20009 were bought in 2019 and 2020 and never show it — they sit at
96–100% of PAM in every year they exist.

## Why this is not our query

Each of these was measured and ruled out on 2026-11-02:

- **Payment type.** All four deals carry the same three `AMOUNT_TYPE_CODE` values, and
  the two clean deals reconcile with all three included. No type-based filter can fix
  the old books without breaking the clean ones.
- **Duplicated payment histories across split cases.** Hashing each case's whole
  post-acquisition payment history and looking for two cases carrying an identical one
  finds 0.06% of SE15044's cash and 0.03% of SE16025's — against 0.11% on the clean
  SE20009.
- **A parent-case link.** `REF_CASE_ID` is 100% NULL on all six deals.
- **Scope.** Both sides are cut to the same PAM `combined_ref` batches and the same
  post-acquisition window.

Two unrelated books from two different sellers peaking in the same year and snapping to
parity in the same year is a reporting change at Intrum, not a property of either book.
The likeliest cause is a migration onto the current reporting platform around 2019/2020.

## The question for Intrum

What does PAM's `COLLTOTAL` exclude on these books before 2020 that it includes after?

## What we do meanwhile

- Cash from 2020 onward is quotable on all four old books.
- A **lifetime** recovery rate on SE15044 or SE16025 is not, until this is answered.
- SE19026 and SE20009 are unaffected and quotable throughout.
