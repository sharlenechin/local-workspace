# PT06002 / Millennium BCP — case bridging, everything measured

Project Iron. Deal **PT06002**, Heimdall, Portugal, Millennium BCP, one-off,
capex 2006-03. PAM: 11,140 acquired cases, EUR 50,596,273 acquisition principal.

Every figure here was measured against the live warehouse on **2026-10-23**,
read-only, and is reproducible from `borrower_to_case.sql` beside this file.

**Read this before quoting any number.** The headline result is simple — you can
bridge 99.3% of the tape to Intrum's cases — but three of the findings below
were discovered by getting the answer wrong first, and one figure still does not
reconcile.

---

## 1. The tape

`NPL Consumer Credit and Small Amounts.xls`, sheet `Sample`, **2,767 rows**.
Two other sheets (`Analsys1`, `Analsys2`) are aggregate portfolio tables, not
loan data.

Three id columns, and the names tell you nothing:

| Column | Distinct | What it actually is |
|---|---:|---|
| **ID A** | 1,487 | **borrower** — 1,243 have one loan, the rest 2 to 51 |
| **ID B** | 2,248 | **loan** — 518 duplicate rows |
| **ID C** | 823 | **sub-account** — `0` on 1,945 rows, a real number on 822 |

Nothing in the tape is a portfolio id. The portfolio is the deal.

### Uniqueness, and why `case_id` cannot be mapped

| Key | Distinct of 2,767 | Unique? |
|---|---:|---|
| ID A | 1,488 | no |
| ID B | 2,249 | **no — 518 duplicates** |
| ID C | 823 | no |
| ID A + ID B | 2,249 | no |
| **ID B + ID C** | **2,767** | **yes** |
| ID A + ID B + ID C | 2,767 | yes |

ID B's duplicates are **not** duplicate rows: across the 130 repeated-ID B
groups, 58 carry a different `PRODUCT CODE` and 108 a different `LOAN AMMOUNT`.
They are separate facilities, and ID C is what distinguishes them — it differs
on 130 of 130.

⚠ **`ID B + ID C` is nevertheless NOT the answer.** The asset-index schema says
of `case_id`: *"the seller/tape per-loan id, exactly as the tape carries it —
never construct one … it is for the seller, not something to synthesise."*
So `case_id` stays **unmapped** and the non-uniqueness is a question for
Millennium. This is the `cases.key_unique` blocker on the agent run
(518 of 2,766 rows, 18.7%).

---

## 2. The bridge — use the BORROWER

```
tape ID A  ──▶  CAT CASES.CLIENT_REF_1  ──▶  CASE_ID  ──▶  CAT TRANSACTIONS
```

| | In tape | Bridged | Coverage |
|---|---:|---:|---:|
| **Borrower (ID A)** | 1,487 | 1,473 | **99.1%** |
| Loan (ID B) | 2,248 | 977 | 43.5% |

By tape row: **2,749 of 2,767 = 99.3%**, reaching **1,473 distinct cases**.

⚠ **DO NOT REPORT THE LOAN RATE AS IF COVERAGE DEPENDED ON IT.** ID B resolves
1,098 rows; ID A already resolved every one of them. Where both fire, they point
at the **same case 1,098 of 1,098 times — 100%**. The loan route adds nothing.

### Why the loan rate is low, and why it does not matter

CAT holds **one case per borrower** for this deal — 11,141 cases, 11,141
borrowers, one each. A borrower with five loans on the tape has one case naming
one of them; the other four were never recorded. That is a property of what the
servicer was given, not a matching weakness.

**Precision is exact.** Of 1,473 bridged borrowers, the case's other reference is
that borrower's own ID B 976 times and own ID C 121 times, and **another
borrower's id 0 times**. Across 2,248 loan ids, zero cross-borrower collisions.
Every concatenation of B and C was tested against the 376 unexplained refs:
**0 matches**. There is no hidden key to decode.

---

## 3. ⚠ MATCH IDS ON ALL VERSIONS, READ MONEY ON THE LATEST

The single most expensive thing to get wrong here.

`CLIENT_REF_1` **changes over a case's life**. Across history a case carries
~2 references; deduped to its latest version it carries exactly 1 (11,141 refs
for 11,141 cases).

| Match | All versions | Latest only |
|---|---:|---:|
| ID A | **99.1%** | 18.0% |
| ID B | 43.5% | 34.9% |

Applying the C1/C2 dedupe guards before matching drops the borrower bridge from
99.1% to 18.0%. Those guards exist so a **balance** is not read off a superseded
row — they are not for id matching. `borrower_to_case.sql` therefore reads every
version for the join and a separate `latest_case` CTE for the amounts.

---

## 4. Nothing reaches loan level, from any source

| Source | One row = | Has a loan key? |
|---|---|---|
| PAM | deal-batch × month | **no** — `ACQCASES` is a count, not an id |
| CAT `CASES` | a case (= a borrower) | the nominated loan only |
| CAT `TRANSACTIONS` | a payment | **no** — 65 columns, none identifies a facility |
| the tape | a loan | n/a |

`ORIG_INV_ID` on `TRANSACTIONS` is populated (3.27m of 9.49m rows, 247,033
distinct) but it is **Intrum's own invoice sequence**, ~22 per case: it matches
our ID A on 0.7%, ID B on 0.4%, ID C on 0.0%. `INVOICES` has **zero rows** for
any `PT06%` portfolio.

So even a perfect loan bridge would not give loan-level collections.
**Build at borrower grain.**

---

## 5. PT06002 is not in PROD

Three dead ends, so nobody retries them:

- **`DIM_CASE`** — 0 of 11,141 CAT cases present.
- **`DIM_BORROWER`** — `CASE_ID` is a 32-char hash, not the servicer's id; `VAT`
  (the NIF) is **0% filled on all 931,266 Portuguese rows**.
- **`BRG_CASE_BORROWER`** — exists and is many-to-many (1.6 borrowers per case,
  7.8 cases per borrower across 144.8m rows), but irrelevant while the deal is
  absent from `DIM_CASE`.

**Raw CAT is the only route.** Portfolio id: `PT06002B000000`.

---

## 6. ✓ The bridge reconciles on money

Borrower **639**: the tape's two loans sum to **7,880.60**; CAT's
`ORIGINAL_CAPITAL` for case `1362422` is **7,880.60**. Exact.

Borrower **360**: tape **1,951.79** vs CAT **4,475.51** — the tape is a *sample*
and holds one of that borrower's loans, so a shortfall is expected here.

---

## 7. ⚠ OPEN — collections do not reconcile

With the benchmark's own guards applied (C2 dedupe, C6 `payment_cost_ind='P'`
and `booking_ind<>'Y'`, C7 sign flip), collections still come to **2 to 4x**
original capital:

| Case | Original capital | Collected | type 1 | type 20 | type 4 |
|---|---:|---:|---:|---:|---:|
| 1362421 | 4,475.51 | 17,286 | 12,111.86 | 2,736.14 | 2,438.00 |
| 1362422 | 7,880.60 | 15,963 | 4,697.59 | 4,920.41 | 6,345.00 |

Splitting by `AMOUNT_TYPE_CODE` does not close it — type 1 alone is 2.7x on
case 1362421. Whether this is genuine interest and costs on a case running since
2006, or the NULL-`ORIG_TR_ID` dedupe weakness the template itself flags
(`ORIG_TR_ID` is NULL on 350 of 1,181 rows for one sampled case), is **not
settled**.

**Do not quote the collections column.** For a defensible figure use
`../../benchmark-dataset/post-registration-benchmark/templates/02_payments.sql`
and its roll-forward check.

---

## 8. What the agent run found

Run `200193b9-5695-4a85-b519-815ab4b5f5dd`, 2026-10-23, succeeded.
13 mappings, 26 unmapped, 7 open questions, **1 blocking failure**.

- `cases.key_unique` — 518 of 2,766 (18.7%). See §1.
- **No payments table produced.** The agent's own note: *"the file contains no
  payment or collection history at all … please confirm whether Millennium BCP
  can supply a payment/collections ledger (D-12 to cut-off)."*
- ⚠ **The cut-off date is inferred, not read** — `2005-12-31`, taken from a
  *"Related to 31/12/2005"* title note on both analysis sheets. PAM's capex year
  is 2006, so it is plausible, but it drives everything downstream and should be
  confirmed against the deal documents.
- `other_balances_at_cutoff` is declared mandatory and is **100% empty**.

---

## Open with the seller

1. The per-loan id — is `ID B + ID C` Millennium's own account/sub-account key,
   so it can be mapped as delivered rather than constructed?
2. Can they supply a payment/collections ledger for this portfolio?
3. Confirm the cut-off date is 2005-12-31.

## Related

`[[pt-asset-index-bridge]]` in memory · `work/asset-index/cloud/CASE-BRIDGING.md`
· `work/benchmark-dataset/post-registration-benchmark/` for the post-registration half
