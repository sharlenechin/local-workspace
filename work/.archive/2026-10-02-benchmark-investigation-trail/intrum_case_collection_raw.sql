-- ============================================================================
-- intrum_case_collection_raw — int_npl_case_collection_conformed, rebuilt from
-- RAW Intrum only: RAW.HYPERION_INTRUM_CAT.TRANSACTIONS, .CASES and
-- RAW.HYPERION_INTRUM_PAM.PAM.
-- GRAIN: one row per (CASE_BK, TRANSACTION_ID). Amounts in the case currency.
--
--   Terminal : mise run sql -- work/intrum_case_collection_raw.sql
--   Notebook : datalake.q("intrum_case_collection_raw")
--
-- ALL-TIME TRANSACTIONS. There is no capex-date lower bound anywhere below.
-- TRANSACTION_DATE spans the full history Intrum delivers for the chosen
-- source system, including everything before the batch's capex date. PAM
-- contributes batch attributes only; it never restricts the date range.
-- CAPEX_DATE and IS_PRE_CAPEX are returned so pre-acquisition activity can be
-- seen and, if ever wanted, filtered downstream — not here.
--
-- ---------------------------------------------------------------------------
-- READ BEFORE TRUSTING A NUMBER
--
-- 1. RAW IS FULL-FILE RE-DELIVERY, NOT A CHANGE FEED. Every extract re-sends
--    that source system's whole transaction history, which is why TRANSACTIONS
--    holds 24.7bn rows for a far smaller number of real ones. Querying it
--    unbounded is neither affordable nor correct. This file pins ONE source
--    system and ONE extract, which is a complete all-time file for that
--    system. Change $source_system and rerun to cover another. Do not remove
--    the filter: the first draft of this file, which resolved the extract by
--    scanning the whole table, was killed with "SQL execution canceled".
--
-- 2. THE SCAN IS PRUNED ON _FILE_PATH, AND IT HAS TO BE. Selecting the extract
--    via parse_json(_FILE_METADATA) forces all 24.7bn rows to be parsed before
--    anything can be filtered, and the query times out. The filters below are
--    LIKE patterns anchored at the START of _FILE_PATH, which Snowflake prunes
--    on. $raw_prefix must stay a literal prefix with no leading '%', or the
--    pruning is lost and the timeout comes back.
--
-- 2b. A TRANSACTIONS EXTRACT IS SPLIT ACROSS PART FILES; A CASES EXTRACT IS
--    NOT: cat.1033.transactions.<ts>.27.parquet vs cat.1137.cases.<ts>.parquet.
--    The extract is therefore matched on its <ts> segment with every part
--    kept. Taking max(_FILE_PATH) would return ONE part of the extract and
--    undercount collections with no error at all.
--
-- 2c. IT IS A SAMPLE BY DEFAULT, AND THE SAMPLE COMES AFTER THE FILE FILTER.
--    SAMPLE binds to the table it follows, so `FROM TRANSACTIONS SAMPLE (1)
--    WHERE _FILE_PATH LIKE ...` would sample 1% of all 24.7bn rows and only
--    then filter, discarding both the pruning and most of the wanted extract.
--    It is applied to the already-filtered subquery instead. Snowflake needs a
--    literal there, so it cannot be a session variable: edit it in place, or
--    delete the SAMPLE clause for a full run of one system. A sampled run is
--    for shape only; no total from it is a real total.
--
-- 3. SURROGATE KEYS DO NOT ALL MATCH PROD. Derivable from these three tables
--    and byte-identical to the warehouse: CASE_DK, BATCH_SK, SEGMENT_SK,
--    SECURITY_CLASS_SK, DEAL_SOURCE_SK, LEGAL_BUYER_DK. Not derivable, so
--    returned as NULL with the business key beside them: PORTFOLIO_SK and
--    DEAL_SK (need Atlas), LEGAL_BUYER_SK (internal ownership SCD), PRODUCT_SK
--    and SOURCE_SYSTEM_SK (dbt seeds). Join to PROD if you need those.
--    LEGAL_BUYER_NAME also skips the internal override seed that PROD applies.
--
-- 4. CASE_SK IS A LOCAL REBUILD, NOT THE WAREHOUSE ONE. It collapses the case
--    history on the same ten attributes int_npl_case_scd_conformed tracks, but
--    two inputs are unavailable here: SOURCE_SYSTEM_SK (seed, so
--    SOURCE_SYSTEM_CODE stands in) and DEFAULT_DATE_ADJUSTED, which needs
--    int_npl_invoices_grouped to back-fill a missing default date from invoice
--    dates. Raw DEFAULT_DATE is used instead, so version boundaries agree with
--    PROD only where DEFAULT_DATE was already populated. Match on CASE_DK.
--
-- 5. AMOUNT IS NEGATED, exactly as stg_intrum_cat__transactions does it — a
--    collection arrives from Intrum as a negative and is flipped to positive.
--
-- 6. THE CONTAINER-CASE AND GR CLOSING-CODE-3 RULES ARE REPRODUCED. Sub-cases
--    are dropped (hyphenated ids in 1033, REAL_CASE_IND = '1' in 2080), and
--    Greek cases closed for migration (code 3) are treated as still open.
--    Dropping either rule double-counts or loses cases.
--
-- 7. BOTH DIMENSION JOINS ARE INNER, as in the model. A transaction whose case
--    was filtered out, or whose batch is absent from PAM, is dropped rather
--    than carried with null attributes. So SUM(AMOUNT) here is <= the raw
--    transaction total by design.
--
-- 8. COUNTRY_ID COMES FROM PAM HERE, not from the source-system seed PROD uses.
--    They agree in the normal case; a batch missing from PAM has no country,
--    but such rows are dropped by the inner join anyway.
-- ============================================================================

set raw_prefix    = 'data-prod-data-raw-sftp-071269be/intrum/cat.';
set source_system = '1033';        -- one Intrum source system per run
set extract_ts    = 'latest';      -- 'latest', or pin one e.g. '20251009T134558'
set row_limit     = 100;


-- ── batch attributes: base_intrum_pam__pam → int_npl_batch_intrum ───────────
with pam_latest as (
    select
        combined_ref,
        -- Intrum writes GE for Germany and UK for Britain; neither is ISO
        case
            when countrycode = 'GE' then 'DE'
            when countrycode = 'UK' then 'GB'
            else countrycode
        end as country_id,
        currency as pam_currency_id,
        substr(portfolioid, 3) as deal_bk,
        left(combined_ref, 10) as segment_bk,
        case serviceline
            when 'PI Secured' then 'Secured'
            when 'Purchased Real Estate' then 'Secured'
            when 'PI Unsecured' then 'Unsecured'
            else serviceline
        end as security_class_name,
        case
            when orange = '1' then 'HEI'
            when blue = '1' then 'LOK'
        end as deal_source_bk,
        legal_buyer_name,
        seller_name as legal_seller_name,
        capex_date_m::date as capex_date,
        parse_json(_file_metadata):servicer::string as servicer_name
    from RAW.HYPERION_INTRUM_PAM.PAM
    -- 'Adjust' batches are internal accounting constructs, not owned portfolios
    where pmode_name = 'Real'
    -- PAM is monthly; keep the latest reported state of each batch
    qualify
        row_number() over (
            partition by combined_ref
            order by
                period_start_date::date desc,
                parse_json(_file_metadata):extract_ts::string desc
        ) = 1
),

batch as (
    select
        combined_ref as batch_bk,
        country_id,
        pam_currency_id,
        deal_bk,
        legal_buyer_name,
        legal_seller_name,
        security_class_name,
        deal_source_bk,
        capex_date,
        md5(cast(
            coalesce(cast(combined_ref as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(servicer_name as text), '_dbt_utils_surrogate_key_null_')
        as text)) as batch_sk,
        md5(cast(
            coalesce(cast(segment_bk as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(servicer_name as text), '_dbt_utils_surrogate_key_null_')
        as text)) as segment_sk,
        md5(cast(coalesce(cast(security_class_name as text),
                          '_dbt_utils_surrogate_key_null_') as text)) as security_class_sk,
        md5(cast(coalesce(cast(deal_source_bk as text),
                          '_dbt_utils_surrogate_key_null_') as text)) as deal_source_sk,
        md5(cast(coalesce(cast(legal_buyer_name as text),
                          '_dbt_utils_surrogate_key_null_') as text)) as legal_buyer_dk
    from pam_latest
),

-- ── which extract to read (one whole file per source system) ────────────────
tx_extract as (
    -- <ts> of the extract to read. split_part on the max path is safe because
    -- <ts> is YYYYMMDDTHHMMSS, so lexical order is chronological order.
    select
        case
            when $extract_ts != 'latest' then $extract_ts
            else split_part(max(_file_path), '.', 4)
        end as extract_ts
    from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS
    where _file_path like $raw_prefix || $source_system || '.transactions.%'
),

case_extract as (
    select
        case
            when $extract_ts != 'latest' then $extract_ts
            else split_part(max(_file_path), '.', 4)
        end as extract_ts
    from RAW.HYPERION_INTRUM_CAT.CASES
    where _file_path like $raw_prefix || $source_system || '.cases.%'
),

-- ── stg_intrum_cat__transactions ────────────────────────────────────────────
-- SAMPLE (1) reads ~1% of the raw rows. Snowflake needs a literal here, so it
-- cannot be parameterised; delete the clause for a full run of one system.
tx_renamed as (
    select
        case_id,
        coalesce(record_updated, update_ts)::timestamp as record_update,
        -- flipped sign: Intrum sends collections negative
        -amount::decimal(38, 2) as amount,
        amount_type_code,
        orig_tr_id,
        transaction_type_code,
        currency as tx_currency_id,
        transaction_date::date as transaction_date,
        banking_date::date as banking_date,
        payment_cost_ind,
        booking_ind,
        pkey,
        parse_json(_file_metadata):system::string as source_system_code,
        parse_json(_file_metadata):servicer::string as servicer_name,
        to_timestamp_ntz(
            parse_json(_file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'
        ) as extracted_at
    -- filter to the one extract FIRST (all its part files), then sample it
    from (
        select *
        from RAW.HYPERION_INTRUM_CAT.TRANSACTIONS
        where _file_path like
            $raw_prefix || $source_system || '.transactions.'
            || (select extract_ts from tx_extract) || '.%'
    ) sample (1)
),

-- ── int_npl_case_collection_intrum ──────────────────────────────────────────
transactions as (
    select
        concat(source_system_code, '-', case_id) as case_bk,
        md5(cast(
            coalesce(cast(servicer_name as text), '_dbt_utils_surrogate_key_null_')
            || '-'
            || coalesce(cast(concat(source_system_code, '-', case_id) as text),
                        '_dbt_utils_surrogate_key_null_')
        as text)) as case_dk,
        record_update,
        -- DK splits a transaction across rows with different pkeys, so the id
        -- is only unique once pkey is concatenated on
        concat(orig_tr_id, coalesce(pkey, '')) as transaction_id,
        transaction_date,
        banking_date,
        transaction_type_code,
        amount,
        amount_type_code,
        tx_currency_id,
        servicer_name,
        source_system_code,
        extracted_at
    from tx_renamed
    -- filtering logic received from Intrum: payments only, unbooked excluded
    where
        payment_cost_ind = 'P'
        and coalesce(booking_ind, 'N') != 'Y'
    qualify
        row_number() over (
            partition by case_bk, transaction_id
            order by record_update desc nulls last, extracted_at desc
        ) = 1
),

-- ── stg_intrum_cat__cases → int_npl_case_base_intrum ────────────────────────
case_source as (
    select
        case_id,
        concat(parse_json(_file_metadata):system::string, '-', case_id) as case_bk,
        long_portfolio_id as batch_bk,
        coalesce(record_updated, update_ts)::timestamp as record_update,
        coalesce(record_updated, update_ts)::date as record_update_date,
        currency_cap_interest as currency_id,
        branch_code as product_bk,
        main_status_code as status_code,
        main_status_date::date as status_date,
        closing_code,
        closing_date::date as closing_date,
        default_date::date as default_date,
        registration_date::date as registration_date,
        origination_date_at_client::date as origination_date,
        is_secured::boolean as secured_flag,
        real_case_ind,
        principal_at_cutoff::decimal(18, 2) as original_principal,
        parse_json(_file_metadata):system::string as source_system_code,
        'intrum' as servicer_name,
        to_timestamp_ntz(
            parse_json(_file_metadata):extract_ts::string, 'YYYYMMDDTHH24MISS'
        ) as extracted_at
    from RAW.HYPERION_INTRUM_CAT.CASES
    where _file_path like
        $raw_prefix || $source_system || '.cases.'
        || (select extract_ts from case_extract) || '.%'
    -- one row per case per day: latest snapshot wins
    qualify
        row_number() over (
            partition by case_bk, record_update_date
            order by record_update desc, extracted_at desc
        ) = 1
),

-- 1033 container cases: the closing date comes from the last closed sub-case,
-- and the container stays open while any sub-case is (hence nulls first)
container_cases_1033 as (
    select
        split_part(case_id, '-', 1) as parent_case_id,
        record_update_date,
        closing_date,
        closing_code
    from case_source
    where real_case_ind = '2' and source_system_code = '1033'
    qualify
        row_number() over (
            partition by split_part(case_id, '-', 1), record_update
            order by closing_date desc nulls first
        ) = 1
),

-- sub-cases to drop: 2080 marks them real_case_ind = '1'
container_cases_2080 as (
    select distinct case_bk
    from case_source
    where real_case_ind = '1' and source_system_code = '2080'
),

cases_renamed as (
    select
        case_source.case_bk,
        md5(cast(
            coalesce(cast(case_source.servicer_name as text),
                     '_dbt_utils_surrogate_key_null_')
            || '-'
            || coalesce(cast(case_source.case_bk as text),
                        '_dbt_utils_surrogate_key_null_')
        as text)) as case_dk,
        case_source.record_update_date,
        case_source.batch_bk,
        case_source.currency_id,
        case_source.product_bk,
        case_source.status_code,
        case_source.status_date,
        -- Greece closes cases on migration (code 3) before reopening them in
        -- the new system; treat those as still open or they are lost entirely
        case
            when case_source.closing_code = '3' and batch.country_id = 'GR' then null
            else coalesce(case_source.closing_code, container_cases_1033.closing_code)
        end as closing_code,
        case
            when case_source.closing_code = '3' and batch.country_id = 'GR' then null
            else coalesce(case_source.closing_date, container_cases_1033.closing_date)
        end as closing_date,
        -- raw default_date: the invoice-based back-fill is unavailable here
        case_source.default_date,
        case_source.registration_date,
        case_source.origination_date,
        case_source.secured_flag,
        case_source.original_principal,
        case_source.source_system_code,
        case_source.extracted_at
    from case_source
    left join batch on case_source.batch_bk = batch.batch_bk
    left join container_cases_2080
        on case_source.case_bk = container_cases_2080.case_bk
    left join container_cases_1033
        on
            split_part(case_source.case_id, '-', 1) = container_cases_1033.parent_case_id
            and case_source.record_update_date = container_cases_1033.record_update_date
    where
        container_cases_2080.case_bk is null
        -- 1033 sub-cases are the hyphenated ids
        and case_source.case_id not like '%-%'
),

-- ── scd_table(): validity ranges per case version ───────────────────────────
case_scd_ranked as (
    select
        cases_renamed.*,
        row_number() over (
            partition by case_bk order by record_update_date asc
        ) as scd_rn,
        coalesce(
            lead(record_update_date) over (
                partition by case_bk order by record_update_date
            ),
            '9999-12-31'::date
        ) as valid_to
    from cases_renamed
),

-- the earliest version is backdated to origination_date, so transactions
-- predating the first servicer delivery still resolve to their case
cases as (
    select
        * exclude (scd_rn),
        case
            when scd_rn = 1 then coalesce(origination_date, record_update_date)
            else record_update_date
        end as valid_from
    from case_scd_ranked
),

-- ── int_npl_case_scd_conformed: collapse to genuine attribute changes ───────
case_hashed as (
    select
        case_dk,
        valid_from as version_from_date,
        extracted_at,
        md5(cast(
            coalesce(cast(status_code as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(status_date as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(closing_code as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(closing_date as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(default_date as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(origination_date as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(registration_date as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(original_principal as text), '_dbt_utils_surrogate_key_null_') || '-'
            || coalesce(cast(secured_flag as text), '_dbt_utils_surrogate_key_null_') || '-'
            -- source_system_sk in PROD; that seed is unavailable here
            || coalesce(cast(source_system_code as text), '_dbt_utils_surrogate_key_null_')
        as text)) as attribute_hash
    from cases
    -- guard against fan-out from the batch join above
    qualify
        row_number() over (
            partition by case_dk, valid_from order by extracted_at desc
        ) = 1
),

-- lag(), not a stored hash, so an A -> B -> A return is kept as three versions
case_deduped as (
    select * from case_hashed
    qualify
        attribute_hash is distinct from lag(attribute_hash) over (
            partition by case_dk order by version_from_date
        )
),

case_versions as (
    select
        case_dk,
        md5(cast(
            coalesce(cast(case_dk as text), '_dbt_utils_surrogate_key_null_')
            || '-'
            || coalesce(cast(version_from_date as text), '_dbt_utils_surrogate_key_null_')
        as text)) as case_sk,
        version_from_date as valid_from,
        coalesce(
            lead(version_from_date) over (
                partition by case_dk order by version_from_date
            ),
            '9999-12-31'::date
        ) as valid_to
    from case_deduped
),

final as (
    select
        batch.country_id,
        -- case currency, falling back to the batch's as the model does
        coalesce(cases.currency_id, batch.pam_currency_id) as currency_id,
        case_versions.case_sk,
        cases.case_dk,
        cases.case_bk,
        batch.batch_sk,
        cases.batch_bk,
        batch.segment_sk,
        batch.security_class_sk,
        batch.deal_source_sk,
        batch.legal_buyer_dk,
        batch.deal_bk,
        batch.legal_buyer_name,
        batch.legal_seller_name,
        batch.security_class_name,
        batch.deal_source_bk,
        -- Atlas / seed keys, not derivable from these three raw tables
        null as portfolio_sk,
        null as deal_sk,
        null as legal_buyer_sk,
        null as product_sk,
        null as source_system_sk,
        cases.product_bk,
        transactions.source_system_code,
        transactions.record_update,
        transactions.transaction_id,
        transactions.transaction_date,
        transactions.banking_date,
        transactions.transaction_type_code,
        transactions.amount,
        transactions.amount_type_code,
        -- reported, never filtered on: this is the whole transaction history
        batch.capex_date,
        transactions.transaction_date < batch.capex_date as is_pre_capex,
        transactions.extracted_at
    from transactions
    -- inner join, as in the model: a transaction on a case the case model
    -- filtered out is dropped rather than carried with null attributes
    inner join cases
        on
            transactions.case_dk = cases.case_dk
            and transactions.transaction_date >= cases.valid_from
            and (
                transactions.transaction_date < cases.valid_to
                or cases.valid_to is null
            )
    left join case_versions
        on
            transactions.case_dk = case_versions.case_dk
            and transactions.transaction_date >= case_versions.valid_from
            and transactions.transaction_date < case_versions.valid_to
    -- inner join on batch mirrors int_npl_batch_conformed in the model
    inner join batch on cases.batch_bk = batch.batch_bk
)

select * from final
order by transaction_date desc
limit $row_limit;
