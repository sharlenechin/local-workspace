# The guards — eleven rules every benchmark query carries

A **guard** is measurement correctness: a rule that applies to every book in the
Intrum estate, whatever the country or seller. Get one wrong and the number is
not approximate, it is wrong — usually silently, and usually in a direction that
flatters the book.

These were established on the Portugal / Millennium build (2026-09-09 to
2026-09-11) and have held on every book since. The working behind each one is in
`work/.archive/2026-10-02-benchmark-investigation-trail/`; the figures are in
`../project-elsa-benchmark/FINDINGS.md`.

⚠ **Guards are not exclusions.** An exclusion is a decision about what belongs
in *one priced book* — unclassifiable debtors, a named batch, a handful of
company loans. Exclusions travel with the deal and ship in
`templates/07_exclusions.sql`. **Guards travel with the feed and are never
optional.** Applying one book's exclusions to another book's scope silently
deletes real loans; omitting a guard silently changes the total.

| | Guard | Why it is not optional |
|---|---|---|
| **C1** | `CASES` is a **change-history feed** — dedupe to the latest version per `CASE_ID` | The feed repeats every version of every record: **147× the cases**. Skip this and the loan count is two orders of magnitude wrong |
| **C2** | `TRANSACTIONS` is a change-history feed too — dedupe on the transaction's own key | **10.8× the transactions** |
| **C3** | `DEBTORS` is one-to-many **and** a change feed — group it **before** it joins | Otherwise it fans every loan out by its debtor slots |
| **C4** | Pin `_file_path` to one Intrum instance, as a **literal prefix** with no leading `%` | `CASE_ID` is unique only **within** an instance. Unpinned, two books' loans merge |
| **C5** | Read **every extract**, not the newest | The newest extract is a **DELTA**. "Latest file only" returns almost nothing |
| **C6** | Payments only: `payment_cost_ind = 'P'` and `booking_ind <> 'Y'` | Otherwise costs and bookings are counted as collections |
| **C7** | `AMOUNT` is stored **sign-flipped** — a collection arrives negative | Sum it raw and collections come out negative, or net against themselves |
| **C8** | Run the batch filter **before** the `qualify` | A loan whose newest version left the batch otherwise vanishes from a book it belongs to |
| **C9** | Drop container cases (hyphenated `CASE_ID`), as dbt does | They are not loans. Instance 1033 is the common offender |
| **C10** | **No `row_number()` on `DEBTORS`** — keep every row tied at the latest version | Update timestamps **tie** at the latest version on most debtor slots, and `TYPE` changes across versions on a third of them. `row_number()` picks arbitrarily, so the corporate/individual split **flips between runs** |
| **C11** | Never bound a payment query by `transaction_date` | **35% of payments have a NULL `transaction_date`.** A date bound drops them silently |

## Three more that are not numbered, and bite just as hard

**The capex floor.** A batch reports collections before Brocc owned it. Floor
every collection window at the batch's own capex date, or the seller's history
lands in Brocc's recovery curve. ⚠ Two acquisition dates exist in the feed —
check which one the book uses.

**PROD is not a second opinion on borrower type.** PROD's borrower key on Intrum
is `source_system_code || '-' || debtor_row_number` — no case in the key, and
one row number shared by 296,041 cases. The resulting loss is **directional**:
it drops companies, so PROD understates the corporate side **by construction**.
Report it to the data team; never fix it in dbt from an analysis.

**Expensive queries are a shared-resource problem.** Anything touching
`TRANSACTIONS` without an instance pin occupies the shared X-Small warehouse for
minutes. Pin first, then widen.

## How to use this file

Before shipping any benchmark number, walk this list against the query that
produced it and say which guards it carries — `templates/01_accounts.sql` and
`02_payments.sql` name them inline in the SQL for exactly this reason. A
reconciliation that cannot name its guards cannot be defended.
