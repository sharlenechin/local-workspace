-- ============================================================================
-- accounts — one row per loan, Project Elsa: Portugal / Millennium + WiZink
--            (Intrum CAT, system 4050)
--
--   RUN      mise run sql -- work/project-elsa-benchmark/accounts.sql
--            datalake.q("work/project-elsa-benchmark/accounts", convert=False)
--   GRAIN    one row per LOAN_ID (raw CASE_ID). Uniqueness asserted, see G1.
--   PAIRS    payments.sql on (PORTFOLIO_ID, LOAN_ID) — identical population.
--   RUNTIME  ~25s.  Money is EUR, not FX-converted.
--   SOURCE   raw CAT feed, plus PROD for DEFAULT_DATE only.
--
-- Millennium figures measured 2026-09-10; WiZink added and everything
-- re-measured 2026-09-16. All re-derivable from this file.
-- ============================================================================
-- RETURNS  150,514 rows × 8 columns, 12 batches, 2 sellers
--
--   SELLER_NAME              'Millennium' (11 batches, 120,543 loans,
--                            906,359,149.41) or 'Wizink' (1 batch, 29,971
--                            loans, 122,891,559.16). Normalised here: PAM
--                            spells them 'Millennium', 'MILLENNIUM' and
--                            'WiZink Bank'. See G7, G8 and E2 for what is
--                            in scope and why.
--   PORTFOLIO_ID             PAM COMBINED_REF — the BATCH ref. See N1.
--   LOAN_ID                  raw CASE_ID. Not PROD's key. See N2.
--   REGISTRATION_DATE        when Intrum OPENED the case, not origination.
--   REGISTRATION_CAPITAL   1,029,250,708.57   ORIGINAL_CAPITAL, principal.
--                            THE ONLY MONEY COLUMN. See READ FIRST 1.
--   DEFAULT_DATE             PROD DERIVED_DEFAULT_DATE. See N3.
--   DEFAULT_DATE_SUSPECT_FLAG  pre-1990 dates (earliest 1978-01-01), flagged
--                              rather than nulled so they can be excluded
--                              deliberately instead of vanishing. All are
--                              Millennium; WiZink has none.
--   PRICING_SEGMENT          SME        12,844 loans  445,511,420.06 capital
--                                        — ALL MILLENNIUM, by rule (E3)
--                            Individual 137,670 loans  583,739,288.51 capital
--
-- ============================================================================
-- READ FIRST — five things that change a number
-- ============================================================================
-- 1. INTEREST IS GONE, AND THAT IS THE POINT (changed 2026-09-16 on request).
--    REGISTRATION_INTEREST and REGISTRATION_BALANCE were returned until this
--    date. They were removed because the two books do not deliver interest the
--    same way and a balance summed across them adds two standards together:
--        Millennium  non-zero on   1,044 of 120,711 loans (0.86%)   5,974,550.16
--        WiZink      non-zero on  27,946 of  29,976 loans (93.2%)  24,029,757.85
--    On Millennium the zeros are non-delivery, not economics: of the loans
--    where interest is exactly 0.00, 97.7% had DEFAULTED BEFORE registration at
--    a median of 3.01 years, and three years in default cannot owe zero
--    interest. PAM agrees — its interest column is 0.00 in all 163 months.
--    → REGISTRATION_CAPITAL is complete on every loan in BOTH books, is the
--      figure that reconciles to PAM, and is now the only money column here.
--      Anything needing a claim including interest must be rebuilt knowingly,
--      per seller, and must not be totalled across the two.
--      ⚠ Downstream cleaning keyed on registration_balance <= 0 must key on
--      registration_capital <= 0 instead. That catches 16 loans, not 7.
--
-- 2. 'SME' IS NOT A SIZE CLASS, AND IT IS MILLENNIUM-ONLY. It means only "a
--    corporate debtor is on the loan". DEBTORS.INCOME is 100% NULL and there is
--    no turnover, headcount or company registration number anywhere in the
--    feed, so a corner shop and a large corporate are indistinguishable. Do not
--    use it for regulatory or capital segmentation.
--    ⚠ WIZINK CARRIES NO SME AT ALL — not because it has none in the feed, but
--    because its 5 company-debtor loans are dropped by rule (E3). Any segment
--    number is therefore a statement about Millennium wearing a portfolio-wide
--    label. Split by SELLER_NAME before quoting one.
--    ⚠ And 11,374 loans (88% of the SME capital) carry BOTH a company and a
--    private debtor. They are SME BY RATIFIED POLICY ("any company involved
--    means SME"), not by evidence. Under the opposite rule (company-only
--    counts) SME would be 1,470 loans. Portfolio totals are robust to this;
--    segment-differentiated pricing is not.
--    ⚠ The EUR figures previously quoted here (398,562,465.78 / 52,177,435.07)
--    were on the REGISTRATION_BALANCE basis, which no longer exists. Rerun the
--    sensitivity on capital before quoting a euro amount for it.
--    ⚠ HAS_COMPANY_DEBTOR / HAS_PRIVATE_DEBTOR WERE RETURNED AND WERE REMOVED
--    2026-09-11 on request, so that sensitivity can no longer be run from the
--    output. The flags still exist as `is_company` / `is_private` in the
--    `enriched` CTE — add them back to the final select to restore it.
--
-- 3. PROD IS NOT USED FOR THE BORROWER TYPE, and must not be reinstated.
--    int_npl_borrower_intrum.sql keys a borrower as source_system_code || '-'
--    || debtor_row_number — no case in the key — but one DEBTOR_ROW_NUMBER is
--    shared by 296,041 cases. The IS_CURRENT loss that follows is
--    ANTI-COMPANY: on the 7,204 loans where raw showed a company and PROD kept
--    only the private one, the C slots had a median 296,041 cases sharing
--    their row number and NONE was unique, against a median of 1 for P slots.
--    PROD understated SME by construction. Dropping IS_CURRENT does not fix it
--    (same borrowed values, plus fan-out).
--    → Full trace, funnel and reconciliation: ../benchmark/archive/borrower_type_mapping.sql.
--      Report the borrower_bk grain to the data team; do not edit dbt here.
--
-- 4. NOTHING HERE IS A CURRENT BALANCE — no dated balance history exists for
--    these books. CASE_BALANCE holds no rows for system 4050 (only 4034, 4042,
--    7006, 7010, none earlier than 2020-05-30); DETAILED_CASE_BALANCE covers
--    only 7006 and 7010; every *_AT_CUTOFF column and ORIGINAL_BALANCE_AT_CLIENT
--    is 100% NULL here. What exists is the balance the case was OPENED with.
--
-- 5. RAW, NOT PROD, FOR COLLECTIONS. PROD.FCT_CASE_COLLECTION holds 42% of this
--    scope's money: int_npl_case_collection_conformed inner-joins collections
--    to the case SCD on transaction_date >= valid_from, and the first case
--    version starts 2014-10-10 — nine years after registration. Every earlier
--    payment is dropped, so PROD cannot answer anything lifetime-shaped.
--
-- ============================================================================
-- COLUMN NOTES
-- ============================================================================
-- N1 PORTFOLIO_ID is the BATCH ref (e.g. PT050030000000) = PAM COMBINED_REF.
--    The name collides with two real columns that mean different things:
--    PAM.PORTFOLIOID is 'PT05003' (7 chars, one per SEVERAL batches) and
--    PROD.DIM_PORTFOLIO.PORTFOLIO_BK is 'HEI-PT25001-U02/2512'. Joining to
--    either matches nothing, silently. First thing to check on an empty join.
-- N2 LOAN_ID is the raw servicer id. PROD uses CASE_BK = '4050-' || case_id,
--    so LOAN_ID does not join to PROD directly. CASE_BK is NOT returned —
--    build it as $source_system || '-' || loan_id if you need it.
-- N3 ⚠⚠ DEFAULT_DATE IS A PROXY ON EVERY SINGLE LOAN — THERE IS NO REAL
--    DEFAULT DATE IN THIS BOOK. Traced through dbt and measured 2026-09-11:
--      · RAW CASES.DEFAULT_DATE is populated on 0 of 120,713 loans.
--      · int_npl_case_intrum.sql substitutes invoice data when the servicer's
--        date is missing, and the rule is COUNTRY-SPECIFIC:
--            DE, CH             -> invoices.max_invoice_date
--            NL, HU, SE, FI     -> invoices.min_due_date   (EARLIEST)
--            everyone else, PT  -> invoices.max_due_date   (LATEST)
--        So every default date here is "the LATEST invoice due date on the
--        case", never an observed default event.
--      · dim_npl_case.sql then computes
--        derived_default_date = coalesce(default_date, origination_date+36m).
--        That second fallback NEVER FIRES here and could not: ORIGINATION_DATE
--        is also 100% NULL on all 120,713. Measured consequence —
--        DEFAULT_DATE and DERIVED_DEFAULT_DATE are IDENTICAL on all 120,713
--        loans, differing on zero. Returning either gives the same column.
--    ⚠ TAKING THE LATEST DUE DATE BIASES THE DATE LATE. Invoices keep being
--    raised after Intrum takes a case on, so max(due date) drifts forward.
--    That is the most likely explanation for the 413 loans (EUR 44,014,486.68,
--    4.8% of balance) whose default date falls AFTER registration, and it
--    cannot be tested against an un-derived value because none exists.
--    ⚠ 2,692 loans (EUR 148,284,254.43, 16.3%) have a default date EXACTLY
--    equal to their registration date. Treat any seasoning, vintage or
--    time-to-recovery analysis built on this column with suspicion.
--    120,713 of 120,713 populated; 117,552 (97.4%) fall before the capex
--    month, the only sense in which it marks "distressed when we bought it".
--    DIM_CASE is keyed on CASE_BK, one current row per case, so the borrower
--    defect in READ FIRST 3 does not touch this column.
-- N4 CLIENT_REF_1 (not returned) is populated and UNIQUE on all 120,713
--    Millennium cases. It is the seller's own loan reference — the join key to
--    anything the seller supplies directly, and the proof that cases = loans.
--    ⚠ NOT RE-VERIFIED ON WIZINK. If you need to join to a WiZink-supplied
--    file, check uniqueness on that batch first rather than assuming it holds.
--
-- ============================================================================
-- GUARDS — each one silently inflates or distorts if removed
-- ============================================================================
-- G1 CASES IS A CHANGE-HISTORY FEED, not a case list: 17,841,296 rows for
--    120,713 loans (147×). Deduped to the latest version per CASE_ID, so a
--    loan resolves to exactly one row and one PORTFOLIO_ID. Verified: 120,543
--    rows, 120,543 distinct LOAN_IDs, CAPITAL + INTEREST = BALANCE =
--    912,333,699.57 exactly. The notebook asserts both; keep the asserts.
-- G2 THE BATCH FILTER RUNS BEFORE THE QUALIFY, AND THAT ORDER IS LOAD-BEARING.
--    Ranking happens only among versions naming an in-scope batch, so a loan
--    whose newest version LEFT the scope keeps its last in-scope batch instead
--    of vanishing. Of the loans returned: 118,400 unchanged; 2,174 whose
--    newest version has a NULL LONG_PORTFOLIO_ID (2,173 on PT15018G000000
--    alone — 12% of it — cause unknown, one for Intrum); 139 sold on to
--    PT24004B000000 "INTRUM INVESTMENT SWITZER". Dedupe-then-filter would drop
--    all 2,313 and 6,856,071.22 of CAT payments PAM still reports. Do not
--    reorder this CTE.
--    · 84 loans name two in-scope batches (PT15018A040000 → PT16023C000000).
--      Latest-in-scope-wins puts all 84 under PT16023C000000: one id each, so
--      no double count, but a real misallocation — PAM bills that money to
--      PT15018A040000. Portfolio totals right; those two batches are not.
-- G3 CASE_ID IS UNIQUE ONLY WITHIN A SOURCE SYSTEM, so it is pinned on
--    _file_path — which is also what makes this affordable. Tested, not
--    assumed: with no instance filter at all, only 4050 holds cases for these
--    batch refs. The pin costs no coverage.
-- G4 ALL EXTRACTS ARE READ, DELIBERATELY. The extracts are not complete
--    re-deliveries of each other: pinning the newest loses 4.6% of money
--    overall and 10.4% on one batch. Never pick one with
--    split_part(max(_file_path),'.',4) — for 4050 that lands on a 1,178-row
--    trailing delta.
-- G5 Container cases (hyphenated CASE_ID) dropped, as int_npl_case_intrum
--    does. A no-op on 4050; kept so $source_system can change.
-- G6 DEBTORS IS ONE-TO-MANY AND A CHANGE-HISTORY FEED (15,264,217 rows here),
--    so it is grouped to one row per CASE_ID before it joins. Joining it
--    directly would multiply every balance.
--    ⚠ NO row_number() IN THAT CTE. RECORD_UPDATE ties at the latest version
--    on 97.4% of debtor slots and TYPE changes across versions on 33.4%, so
--    picking one row resolves arbitrarily and PRICING_SEGMENT flips between
--    runs. Every row tied at the latest version is kept and the flags OR-ed:
--    deterministic, and a genuinely ambiguous slot sets both, so 'C' wins by
--    the stated rule rather than by a coin toss.
-- G7 THE SELLER MATCH IS A REGEX, NOT A LIKE, and it must stay one. PAM spells
--    these three ways — 'Millennium', 'MILLENNIUM', 'WiZink Bank' — so an
--    equality test drops rows and a bare LIKE cannot express two sellers.
--    $sellers is an alternation ('MILLENNIUM|WIZINK') wrapped in '.*(...).*'.
--    Widen it by adding an alternative, never by removing the anchor.
-- G8 DEAL_TYPE_DESC = 'One-off' EXCLUDES THE WIZINK FORWARD FLOW, and it is
--    load-bearing. PAM holds 133 WiZink batches: 129 are 'Ongoing' — the
--    monthly forward-flow deliveries, EUR 45,309,048.67 of capex and
--    EUR 54,294,403.41 of collections — and 4 are 'One-off'. Without this
--    predicate the benchmark silently becomes a forward-flow book.
--    · A no-op on Millennium: all 14 of its batches are already 'One-off'.
--    · 5 of the 129 have NO cases in CAT at all while reporting
--      EUR 379,244.37 of PAM collections. They are excluded here by deal type,
--      not by $exclude_batches, so that number never reaches the output — but
--      it is a real feed gap and it is on the Intrum list.
--    · Two 2017 forward-flow batches have never collected anything on
--      EUR 278,844.63 of capex. Also Intrum's to explain.
--
-- ============================================================================
-- EXCLUSIONS — both at the FINAL SELECT, so every figure above describes the
-- full population and the guards stay comparable
-- ============================================================================
--   · E1 — 169 loans with no P and no C anywhere in raw: unclassifiable, so
--     unpriceable. 168 Millennium (was 335 while PROD still decided the type)
--     and 1 WiZink.
--   · E3 — WIZINK'S 5 COMPANY-DEBTOR LOANS, dropped on instruction so the
--     book is carried as pure consumer. EUR 30,332.57 of capital and
--     EUR 14,363.18 of lifetime collections across all five; 0.02% of the
--     batch. Two of the five also carry a private debtor, so they are 'SME'
--     only under the company-wins policy of READ FIRST 2.
--     ⚠ MILLENNIUM IS NOT TREATED THIS WAY. It keeps its 12,844 SME loans,
--     EUR 450,739,900.85 — about half its balance. The asymmetry is deliberate
--     and it is why PRICING_SEGMENT must be read per seller.
--     ⚠ payments.sql applies the same rule in its priceable_loans CTE. Change
--     one file and you must change the other, or the two stop pairing. The
--     notebook asserts this.
--   · E2 — $exclude_batches, six batches. Set it to '' to return them.
--     THREE MILLENNIUM, unchanged since 2026-09-10: PAM reports collections
--     and CAT has no payments.
--       PT070040000000  the only one that changes the output: 2 loans holding
--                       EUR 2.00 of capital each against PAM's 340,000.00,
--                       registered 279 days after capex where every other
--                       batch lands within -2 to +40 days. Never paid.
--       PT06014B010000  no cases in CAT under any source system. PAM reports
--                       660,000.00. A feed gap, not an empty book.
--       PT15018A040000  its 84 cases resolve to PT16023C000000 (G2), so it was
--                       never in the output. PAM puts ACQUISITIONPRINCIPAL at
--                       18,551,110.00 against 3,452,055.62 of registration
--                       balance on those loans — 15.1m of acquired principal
--                       with no loans behind it. Second-largest Intrum item.
--     ⚠ TWO OF THE THREE ARE NOT COLLECTIONS. PT070040000000 and
--     PT06014B010000 each post ONE month equal to their own
--     ACQUISITIONPRINCIPAL to the cent, in the capex month. No other batch, in
--     ~2,500 collecting months, ever does. EUR 1,000,000.00 of "collections"
--     across the two must not be counted as cash. See work/intrum-escalations.md.
--
--     THREE WIZINK, added 2026-09-16. These fail a RECONCILIATION, not a
--     presence test: CAT's collections must land within ±10% of PAM's over the
--     SAME WINDOW (both cut at the CAT extract, 2026-01 — see payments.sql
--     READ FIRST 2, a whole-against-whole ratio is not like-for-like).
--       PT19007D010000   67.2% of PAM. 3,604 loans against PAM's 4,633
--                        accounts, and AGE_OF_DEBT delivered on 7.2% of them.
--       PT19013A020000  153.1% of PAM. Over-delivery this large is not
--                        pre-capex cash. Unexplained; one for Intrum.
--       PT19013B010000   39.2% of PAM. 232 loans against PAM's 310 accounts.
--     The one WiZink batch that survives, PT18019A000000, reads 104.50% — and
--     that is explained: it holds EUR 2,368,723.41 of cash dated before its own
--     2018-12 capex month (earliest 2018-09-03), which PAM structurally cannot
--     include because a batch's PAM life starts at acquisition. Net of it the
--     batch reconciles at 99.13%.
--     ⚠ MEASURE PRE-CAPEX CASH FROM THIS FILE, NOT FROM A SINGLE-BATCH QUERY.
--     Scoping `cases` to one batch makes latest-in-scope-wins (G2) resolve
--     loans into it that belong to other batches, which dragged an apparent
--     EUR 2,375,619.20 "from 2016" into an earlier draft of this note. With
--     the full scope in place those loans go where they belong.
--     ⚠ THE RULE WAS APPLIED ON BOTH BASES AND GIVES THE SAME TWELVE BATCHES.
--     Lifetime-against-lifetime the four WiZink one-offs read 100.7%, 64.0%,
--     143.9% and 38.7%, so the answer does not hinge on where the cut falls.
--     The eleven Millennium batches run 98.72%-105.74% and all pass.
--
-- ============================================================================
-- CROSS-CHECKS — reassurance that the column is sensible, NOT definitions
-- ============================================================================
--   Roll-forward closes: ORIGINAL_CAPITAL 906,554,742.21 vs REMAINING_CAPITAL
--   759,751,422.46 + collections 160,228,394.35 = 919,979,816.81, within
--   1.48%. The residual is write-offs, fees and accrual. (Full population; as
--   returned it is 120,543 loans, 912,333,699.57 of balance and 160,045,164.05
--   of collections.) A wrong opening balance would not close.
--
--   REGISTRATION_CAPITAL vs PAM ACQUISITIONPRINCIPAL, per batch — these are
--   DIFFERENT QUANTITIES (deal-level acquired principal vs the sum of what
--   each case was opened with), so agreement is reassurance, not proof:
--     PT05007C  100.0    PT07010C  100.0    PT06002B  100.0    PT08010C  100.0
--     PT07007C  100.3    PT16023C  101.8    PT15018G  103.2    PT09006D  104.6
--     PT08018B  109.7    PT06014B   94.0    PT050030  126.0  <- diverges
--     PT18019A  100.9  (WiZink — tightest agreement of any large batch)
--   Millennium: capital 102.562% of PAM. Lifetime recovery 17.658% on capital,
--   18.106% on PAM principal — say which denominator you used.
--   ⚠ DO NOT BLEND A RECOVERY RATE ACROSS THE TWO SELLERS WITHOUT SAYING SO.
--   They are 13 and 8 years apart in vintage and were bought at ~11% and ~20%
--   of face. A blended rate describes no book that exists. Split on
--   SELLER_NAME, which is why that column is returned.
--   · PT050030000000 WAS INVESTIGATED and registration capital survives.
--     Ruled out: sibling batches (PT05003 has exactly one batch in PAM);
--     post-acquisition additions (all 28,444 cases registered within ten weeks
--     of capex); and the one that would have mattered, one debt split across
--     several cases — CLIENT_REF_1 is unique on all 28,444, so no principal is
--     double-counted. What is unexplained is why PAM is 6.2m lower: a question
--     about PAM, for Intrum. ⚠ Its recovery rate reads 40.44% or 50.97%
--     depending on the denominator, so never quote one without saying which.
--   · PT08018B000000 at +9.7% has NOT been investigated.
--
-- ============================================================================
-- JOINING TO payments.sql WITHOUT DOUBLE COUNTING
-- ============================================================================
--   accounts   120,543 rows — one per loan
--   payments   474,900 rows over 52,062 loans that ever paid
-- Join them raw and REGISTRATION_BALANCE repeats once per payment row; an
-- INNER join also drops the 68,481 loans that never paid, so the total falls
-- AND the survivors multiply. Aggregate to loan level FIRST:
--     collections as (select loan_id, sum(total_collections) as collections
--                     from payments group by loan_id)
--     ... from accounts left join collections using (loan_id)
-- LEFT, so a loan that never paid keeps its row. Same rule for any other
-- one-to-many source (DEBTORS, INVOICES, LEGAL_STEPS): group, then join.
-- ⚠ Everything here is EUR and payments.sql no longer carries a currency
-- column. Verified 2026-09-11: CASES.CURRENCY_CAP_INTEREST is 'EUR' on all
-- 120,713 loans, no nulls and no other value. See payments.sql N5 before
-- reusing either file outside PT / MILLENNIUM.
--
-- ============================================================================
-- NOT RETURNED, AND WHY
-- ============================================================================
--   ACCRUED_INTEREST      135,711,978.79 — accrued SINCE registration, so it
--                         belongs to a different point in time. ⚠ 23× the
--                         registration interest: when someone says "the
--                         interest", establish which they mean.
--                         ⚠ TESTED FOR INCLUSION 2026-09-11 AND REJECTED. It
--                         fails the same test as ORIGINAL_INTEREST, harder:
--                           > 0        14,147 loans (11.72%)  135,711,978.79
--                           = 0.00     58,610 loans (48.55%)  median 19.09 yrs
--                                                             in the book
--                           NULL       47,954 loans (39.73%)  median 18.57 yrs
--                         So 88.28% of a defaulted book that has sat with
--                         Intrum ~19 years shows NO accrual at all.
--                         ⚠ AND IT RUNS BACKWARDS TO AGE. Accrued interest as a
--                         share of batch capital is HIGHEST on the two
--                         YOUNGEST batches and lowest on the oldest:
--                           PT16023C  9.0 yrs  16.56%   PT06002B 19.9 yrs 9.65%
--                           PT15018G  9.8 yrs  17.26%   PT05007C 20.3 yrs 9.10%
--                           PT050030 20.5 yrs   2.72%  <- 20 years, 2.7%
--                         A real accrual grows with time. This shrinks, so it
--                         tracks when Intrum started capturing the field, not
--                         what the borrower owes. 76.7% of it (104,123,079.18)
--                         sits on those two 2016 batches.
--                         ⚠ ALSO UNDATED AND INCOHERENT: only 5,001 of the
--                         14,147 loans that have an amount carry
--                         ACCRUED_INTEREST_REG_DATE, while 12,108 loans with
--                         ZERO accrual do carry one.
--                         → Adding it would inflate the denominator ~15% and
--                           drop every recovery rate UNEVENLY BY BATCH, on
--                           delivery artefacts rather than economics. It would
--                           also mix a figure as at the extract date into a
--                           balance as at registration, ~18 years apart.
--                           ⚠ THE PREVIOUS NOTE HERE SAID "on 72,759 loans",
--                           which counted NON-NULL rows including the zeros.
--                           Only 14,147 loans actually carry a figure. Do not
--                           quote 72,759 as coverage.
--   Costs and fees        There is NO cost component at registration in this
--                         feed. Checked column by column: ORIGINAL_UNDUE_CAPITAL
--                         and PURCHASE_AMOUNT are filled but sum to 0.00;
--                         ORIG_CAPITAL_VAT, ORIGINAL_BALANCE_AT_CLIENT, all
--                         *_AT_CUTOFF, LATE_PAYMENT_FEE, SECURED_ADMITTED_AMOUNT,
--                         UNSECURED_ADMITTED_AMOUNT and CUSTOM_AMOUNT_1 are
--                         100% empty. Costs exist only as REMAINING_* — as at
--                         the latest delivery, undated — totalling 8,541,391.95
--                         (0.94% of capital). Mixing those into a registration
--                         figure would span two points in time years apart.
--                         So say "at registration", never "total owed".
--   Insolvency            BANKRUPTCY_RECORD covers 4.87% of loans and every
--                         date falls in a 23-month window (2018-10 to 2020-09)
--                         for books registered 2005-2016. BANKRUPTCY_END_DATE
--                         is 100% NULL here, there is no usable record key,
--                         and PROD does not model the table at all. It cannot
--                         mark distress at acquisition — DEFAULT_DATE can (N3).
--                         Ask Intrum for the missing years first.
--   LEGAL_EBA_TYPE and    Both needed the PROD borrower join (READ FIRST 3),
--   PRICING_SEGMENT_SOURCE so neither is a one-line restore any more. For EBA
--                         vocabulary, map from PRICING_SEGMENT exactly as the
--                         data team's own seed does — one-to-one, and it
--                         cannot express SME for Intrum at all:
--                         intrum,P,Private,Households
--                         intrum,C,Company,Non-financial corporations
--
-- SEE ALSO  ../benchmark/archive/borrower_type_mapping.sql (the PROD trace and reconciliation),
--           ../benchmark/archive/pam_cat_match.sql (CAT vs PAM), work/intrum-escalations.md.
-- ⚠ NOTHING MAY FOLLOW THE FINAL SEMICOLON, not even a comment: run_sql.py
-- splits on ';' and a trailing comment-only chunk fails.
-- ============================================================================

set country         = 'PT';
set sellers         = 'MILLENNIUM|WIZINK';   -- regex alternation; see G7
set deal_type       = 'One-off';             -- excludes WiZink forward flow; see G8
set source_system   = '4050';
set raw_prefix      = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set exclude_batches = 'PT06014B010000,PT070040000000,PT15018A040000,'
                   || 'PT19007D010000,PT19013A020000,PT19013B010000';


-- Scope: PAM collapsed to one row per batch before anything joins to it.
-- seller_name is carried through because it is single-valued per COMBINED_REF
-- (verified 2026-09-16: zero batch refs name two sellers), so the join below
-- cannot fan out.
with batches as (
    select distinct
        combined_ref,
        -- Normalised, because PAM spells them three ways: 'Millennium',
        -- 'MILLENNIUM' and 'WiZink Bank'. The output must not carry that.
        iff(upper(seller_name) like '%WIZINK%', 'Wizink', 'Millennium') as seller_name
    from RAW.HYPERION_INTRUM_PAM.PAM
    where _file_path = (
              select max(_file_path)
              from RAW.HYPERION_INTRUM_PAM.PAM
              where _file_path like '%/pam.pam.pam.2%'
          )
      and pmode_name = 'Real'
      and coalesce(is_ownership_change, 0) = 0
      and countrycode like $country
      and regexp_like(upper(seller_name), '.*(' || $sellers || ').*')     -- G7
      and deal_type_desc = $deal_type                                     -- G8
),

-- One row per loan: its latest version, across every extract (G1-G5).
cases as (
    select
        c.long_portfolio_id              as portfolio_id,
        c.case_id                        as loan_id,
        c.registration_date::date        as registration_date,
        c.original_capital               as registration_capital
    from RAW.HYPERION_INTRUM_CAT.CASES as c
    where c._file_path like $raw_prefix || $source_system || '.cases.%'   -- G3, G4
      and c.long_portfolio_id in (select combined_ref from batches)       -- before qualify: G2
      and c.case_id not like '%-%'                                        -- G5
      -- Only bites if $source_system becomes 2080; a no-op on 4050.
      and not ($source_system = '2080' and coalesce(c.real_case_ind, '') = '1')
    qualify row_number() over (
        partition by c.case_id
        order by coalesce(c.record_updated, c.update_ts)::timestamp desc nulls last
    ) = 1                                                                 -- G1, G2
),

-- Borrower type, one row per loan (G6). Scoping to the case list before the
-- window runs took this from 36s to 28s — keep that filter.
debtor_type as (
    select
        d.case_id,
        max(iff(d.type = 'C', 1, 0)) as has_company_debtor,
        max(iff(d.type = 'P', 1, 0)) as has_private_debtor
    from (
        select
            b.case_id,
            b.type,
            coalesce(b.record_updated, b.update_ts)::timestamp as ts,
            max(coalesce(b.record_updated, b.update_ts)::timestamp) over (
                partition by b.case_id, b.debtor_row_number
            ) as max_ts
        from RAW.HYPERION_INTRUM_CAT.DEBTORS as b
        where b._file_path like $raw_prefix || $source_system || '.debtors.%'
          and b.case_id in (select loan_id from cases)
          and coalesce(b.deleted, 0)  = 0
          and coalesce(b.archived, 0) = 0
          and coalesce(b.unlinked, 0) = 0
    ) as d
    where d.ts = d.max_ts   -- EVERY row at the latest version, not one of them
    group by d.case_id
),

-- Both joins are LEFT and both right sides are one row per loan (DIM_CASE by
-- IS_CURRENT_FLAG, debtor_type by its group by), so the row count cannot move.
enriched as (
    select
        b.seller_name,
        c.portfolio_id,
        c.loan_id,
        c.registration_date,
        c.registration_capital,
        dc.derived_default_date::date          as default_date,
        dc.derived_default_date < '1990-01-01' as default_date_suspect_flag,
        dt.has_company_debtor                  as is_company,
        dt.has_private_debtor                  as is_private
    from cases as c
    -- One row per batch (see the `batches` CTE), so this cannot fan out.
    inner join batches as b
        on b.combined_ref = c.portfolio_id
    left join PROD.NPL_COMMON.DIM_CASE as dc
        on  dc.case_bk = $source_system || '-' || c.loan_id   -- N2: CASE_BK, not CASE_ID
        and dc.is_current_flag
    left join debtor_type as dt
        on dt.case_id = c.loan_id
)

select
    seller_name,
    portfolio_id,
    loan_id,
    registration_date,
    registration_capital,                     -- the ONLY money column; see READ FIRST 1
    default_date,
    default_date_suspect_flag,
    -- Company wins: ratified policy, not a reading of the data. READ FIRST 2.
    iff(is_company = 1, 'SME', 'Individual') as pricing_segment
from enriched
where (is_company = 1 or is_private = 1)
  -- E3: WiZink is carried as a consumer book. Its 5 company-debtor loans
  -- (EUR 30,332.57 of capital) are dropped on instruction. Millennium keeps
  -- its 12,844 SME loans, so PRICING_SEGMENT is only ever 'SME' on Millennium.
  and not (seller_name = 'Wizink' and is_company = 1)
  and not array_contains(portfolio_id::variant, split($exclude_batches, ','))
order by seller_name, portfolio_id, loan_id;
