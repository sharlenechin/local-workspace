"""Where each attribute lives after registration: in RAW (Intrum's CAT and PAM feeds) and in
PROD NPL_COMMON (the same feeds, cleaned by dbt).

Both are asked at CASE level, because that is the question: do we have this for each case?
So RAW is Intrum's case-level CAT feed only. PAM is one row per batch and month, so an
attribute only PAM carries counts as not found; PAM is used in E.3, as the yardstick CAT's
collections are reconciled against.

RAW maps an attribute to its CAT table.column, or None when CAT has no column for it. NPL maps it to its NPL_COMMON table.column and to the *_fill column of
post_registration_quality.sql that measures it, or None when dbt does not carry it.
Columns checked against `describe table` on 2026-11-03.
"""

PAM_ONLY = "(PAM only: batch level)"

RAW: dict[str, str | None] = {
    # --- Section B: borrower ---
    "age": "DEBTOR_ADDITIONAL_INFO.birthdate / birthyear",
    "gender": "DEBTORS.gender",
    "town": "DEBTORS.city",
    "city_region": "DEBTORS.zip_code",
    "has_phone_number": "DEBTORS.phone_number_mobile / _home / _work",
    "has_email": "DEBTORS.email",
    "individual_vs_corporate": "DEBTORS.legal_type",
    "deceased_flag": None,
    "has_codebtor": "DEBTORS.debtor_row_number (several per case)",
    "has_guarantor": None,
    "has_multiple_cases": "DEBTORS.debtor_number (across cases)",
    "employment_type": "DEBTORS.occupation",
    "net_income": "DEBTORS.income",
    "credit_score": "CASES.score / DEBTORS.credit_rating",
    "vulnerable_flag": None,
    # --- dates ---
    "origination_date": "CASES.origination_date_at_client",
    "default_date": "CASES.default_date",
    "debt_age": "CASES.age_of_debt",
    "cut_off_date": None,
    "registration_date": "CASES.registration_date",
    "last_payment_date": "INVOICES.last_payment_date",
    "prior_capex_date": None,  # PAM only: batch level
    # --- balances ---
    "registration_balance": "CASES.original_capital + original_interest",
    "cut_off_balance": "CASES.face_value_at_cutoff",
    "registration_principal": "CASES.original_capital",
    "cut_off_principal": "CASES.principal_at_cutoff",
    "registration_interest": "CASES.original_interest",
    "cut_off_interest": "CASES.interest_at_cutoff",
    "registration_fee": "INVOICES.original_fees",
    "cut_off_fee": "CASES.expenses_at_cutoff",
    "default_balance": None,
    "legal_claim_amount": "LEGAL_INFO.capital_at_legal_start / verdict_amount",
    "original_amount": "CASES.original_balance_at_client",
    "interest_rate": "CASES.interest_rate",
    # --- product and deal ---
    "purchase_price": None,  # ours is in Atlas, not in any servicer feed
    "prior_purchase_price": "CASES.purchase_price",  # Intrum's own price, per case
    "product_type": "CASES.product_id / orig_product_name",
    "seller_name": "CASES.portfolio_sellers_name",
    "pricing_segment": None,
    "deal_flow_type": None,  # PAM only: batch level
    "country": "DEBTORS.country_code",
    "case_count_at_cut_off": "CASES.principal_at_cutoff (cases carrying it)",
    "case_count_at_registration": "CASES.case_id",
    "currency": "TRANSACTIONS.currency",
    "account_status": "CASES.main_status_code / closing_date",
    "days_past_due": None,
    "npl_backstop_flag": None,
    # --- collateral ---
    "has_collateral": "CASES.is_secured",
    "collateral_value": None,
    "collateral_type": None,
    # --- collections ---
    "monthly_collection_sum": "TRANSACTIONS.amount + transaction_date",
    "monthly_collection_count": "TRANSACTIONS.amount + transaction_date",
    "collection_months_pre_cut_off": "TRANSACTIONS.transaction_date",
    "collection_months_pre_registration": "TRANSACTIONS.transaction_date + CASES.registration_date",
    "collection_months_post_registration": "TRANSACTIONS.transaction_date + CASES.registration_date",
    "paying_case_count_pre_cut_off": "TRANSACTIONS.case_id",
    "paying_case_count_pre_registration": "TRANSACTIONS.case_id + CASES.registration_date",
    "paying_case_count_post_registration": "TRANSACTIONS.case_id + CASES.registration_date",
    "payer_flag": "TRANSACTIONS.case_id",
    "payment_plan_flag": "INSTALLMENT.installment_id",
    "third_party_managed_flag": "ASSIGNMENT.agent_id",
    "current_servicer_name": "ASSIGNMENT.agent_name",
    "prior_servicer_count": "ASSIGNMENT.assignment_id (count)",
    "total_collections_pre_cut_off": "TRANSACTIONS.amount",
    "total_collections_post_registration_cat": "TRANSACTIONS.amount + CASES.registration_date",
    "total_collections_post_registration_pam": None,  # PAM only: batch level
    # --- Section A: legal ---
    "limitation_date": "CASES.statute_barred_date",
    "final_limitation_date": None,
    "statute_barred_flag": "CASES.statute_barred_date",
    "bankruptcy_flag": "BANKRUPTCY_RECORD.insolvency_open_date",
    "insolvency_flag": "BANKRUPTCY_RECORD.insolvency_open_date",
    "insolvency_date": "BANKRUPTCY_RECORD.insolvency_open_date",
    "insolvency_age": "BANKRUPTCY_RECORD.insolvency_open_date",
    "judicial_liquidation_flag": "COMPANY_DATA.liquidation_date",
    "collective_proceedings_flag": "COMPANY_DATA.liquidation_date",
    "debt_restructuring_flag": "CASES.restructuring_date",
    "debt_adjustment_flag": "CASES.restructuring_date",
    "debt_settlement_flag": "CASES.restructuring_date",
    "debt_relief_flag": "CASES.restructuring_date",
    "statutory_debt_restructuring_flag": "CASES.restructuring_date",
    "collective_debt_settlement_flag": "CASES.restructuring_date",
    "over_indebtedness_flag": "CASES.restructuring_date",
    "overindebtedness_flag": "CASES.restructuring_date",
    "debt_protection_flag": "CASES.restructuring_date",
    "individual_voluntary_arrangement_flag": "CASES.restructuring_date",
    "enforcement_authority_flag": "LEGAL_STEPS.legal_step / LEGAL_INFO.amount_paid_to_bailiff",
    "enforcement_flag": "LEGAL_STEPS.legal_step",
    "bailiff_flag": "LEGAL_INFO.amount_paid_to_bailiff",
    "bailiff_court_flag": "LEGAL_STEPS.legal_step",
    "attachment_flag": "DEBTORS.attachment_exists",
    "debt_enforcement_stage": "LEGAL_STEPS.legal_step",
    "titled_flag": "CASES.is_titled",
    "enforceable_title_flag": "CASES.is_titled",
    "title_date": "CASES.judgement_date",
    "title_age": "CASES.judgement_date",
    "judgment_flag": "CASES.judgement_date",
    "county_court_judgment_flag": "CASES.judgement_date",
    "court_order_flag": "CASES.judgement_date",
    "payment_order_flag": "CASES.judgement_date",
    "injunction_flag": "CASES.judgement_date",
    "injunction_date": "CASES.judgement_date",
    "injunction_age": "CASES.judgement_date",
    "judicialised_flag": "LEGAL_INFO.legal_registration_date / CASES.court_procedure",
    "address_unknown_flag": "DEBTORS.gone_away",
    "loss_certificate_flag": None,
    "debt_management_company_flag": None,
    "unenforceable_flag": None,
}

# attribute -> (NPL_COMMON table.column, the *_fill column that measures it)
NPL: dict[str, tuple[str, str] | None] = {
    "gender": ("DIM_BORROWER.gender", "gender_fill"),
    "individual_vs_corporate": ("DIM_BORROWER.legal_eba_type", "legal_type_fill"),
    "has_codebtor": ("BRG_CASE_BORROWER (borrowers per case)", "borrower_fill"),
    "has_multiple_cases": ("DIM_BORROWER.borrower_bk (across cases)", "borrower_fill"),
    "credit_score": ("DIM_BORROWER.credit_rating", "credit_rating_fill"),
    "origination_date": ("DIM_CASE.origination_date", "origination_date_fill"),
    "default_date": ("DIM_CASE.default_date", "default_date_fill"),
    "debt_age": ("DIM_CASE.default_date + registration_date", "default_date_fill"),
    "registration_date": ("DIM_CASE.registration_date", "registration_date_fill"),
    "registration_principal": ("DIM_CASE.original_principal", "original_principal_fill"),
    "account_status": ("DIM_CASE.status_code", "status_code_fill"),
    "npl_backstop_flag": ("DIM_CASE.backstop_date", "backstop_date_fill"),
    "has_collateral": ("DIM_CASE.secured_flag", "secured_flag_fill"),
    # The status lookup decodes insolvency (and only open/closed besides).
    "insolvency_flag": ("DIM_CASE.status_code", "status_code_fill"),
    "bankruptcy_flag": ("DIM_CASE.status_code", "status_code_fill"),
    "judicial_liquidation_flag": ("DIM_CASE.status_code", "status_code_fill"),
    "collective_proceedings_flag": ("DIM_CASE.status_code", "status_code_fill"),
    "product_type": ("FCT_CASE_SNAPSHOT_DAILY.product_sk -> DIM_PRODUCT", "product_fill"),
    "pricing_segment": ("FCT_CASE_SNAPSHOT_DAILY.segment_sk -> DIM_SEGMENT", "segment_fill"),
    "currency": ("FCT_CASE_SNAPSHOT_DAILY.currency_id", "currency_fill"),
    "country": ("FCT_CASE_SNAPSHOT_DAILY.country_id", "country_fill"),
    "payment_plan_flag": ("FCT_CASE_SNAPSHOT_DAILY.forbearance_flag", "forbearance_fill"),
    "seller_name": ("DIM_BATCH.legal_seller_name", "seller_fill"),
    "deal_flow_type": ("DIM_BATCH.deal_type", "deal_type_fill"),
    "current_servicer_name": ("DIM_BATCH.servicer_name", "servicer_fill"),
    "prior_capex_date": ("DIM_BATCH.legacy_capex_date", "legacy_capex_date_fill"),
    "prior_purchase_price": ("DIM_BATCH.legacy_capex_amount", "legacy_capex_amount_fill"),
    "case_count_at_registration": ("DIM_CASE.case_bk + registration_date", "registration_date_fill"),
    "purchase_price": ("DIM_PORTFOLIO.price_gross", "price_fill"),
    "last_payment_date": ("FCT_CASE_COLLECTION.collection_date (latest)", "cat_collection_fill"),
    "monthly_collection_sum": ("FCT_CASE_COLLECTION.amount", "cat_collection_fill"),
    "monthly_collection_count": ("FCT_CASE_COLLECTION.amount", "cat_collection_fill"),
    "collection_months_pre_cut_off": ("FCT_CASE_COLLECTION.collection_date", "cat_collection_fill"),
    "collection_months_pre_registration": ("FCT_CASE_COLLECTION + DIM_CASE.registration_date", "cat_collection_fill"),
    "collection_months_post_registration": ("FCT_CASE_COLLECTION + DIM_CASE.registration_date", "cat_collection_fill"),
    "paying_case_count_pre_cut_off": ("FCT_CASE_COLLECTION.case_id", "cat_collection_fill"),
    "paying_case_count_pre_registration": ("FCT_CASE_COLLECTION + DIM_CASE.registration_date", "cat_collection_fill"),
    "paying_case_count_post_registration": ("FCT_CASE_COLLECTION + DIM_CASE.registration_date", "cat_collection_fill"),
    "payer_flag": ("FCT_CASE_COLLECTION.case_id", "cat_collection_fill"),
    "total_collections_pre_cut_off": ("FCT_CASE_COLLECTION.amount", "cat_collection_fill"),
    "total_collections_post_registration_cat": ("FCT_CASE_COLLECTION.amount", "cat_collection_fill"),
    "total_collections_post_registration_pam": ("FCT_PORTFOLIO_SNAPSHOT_MONTHLY.gross_cash_recoveries", "pam_collection_fill"),
}

# NPL_COMMON grains that are not case level: these count as not found in E.2.
NOT_CASE_LEVEL = {"batch", "pam"}


def raw_feed(attr: str) -> str | None:
    """'CAT' when raw CAT has a case-level column for the attribute, else None."""
    return "CAT" if RAW.get(attr) else None


# Which NPL_COMMON grain an attribute is measured on, so a deal is checked for rows there.
def npl_grain(attr: str) -> str | None:
    loc = NPL.get(attr)
    if loc is None:
        return None
    fill = loc[1]
    if fill == "pam_collection_fill":
        return "pam"
    if fill == "cat_collection_fill":
        return "collections"
    if fill in {"seller_fill", "deal_type_fill", "servicer_fill", "legacy_capex_date_fill",
                "legacy_capex_amount_fill", "legacy_case_count_fill", "price_fill"}:
        return "batch"
    return "case"
