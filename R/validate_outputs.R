#' Validation report for the analytical layer.
#'
#' Cross-checks pipeline outputs against externally published anchor numbers
#' (ATO Taxation Statistics 2023-24 edition, ACNC published AIS counts) and
#' internal consistency rules. Returns a tibble of checks (one row per check)
#' and prints a readable summary. A check failing does NOT stop the pipeline;
#' failures are surfaced loudly for human review.

validate_outputs <- function(charity_master_path, dgr_counts_path,
                             ancillary_ts_path, panel_path,
                             gap_path, scenarios_path, exposure_path) {
  pq <- function(paths) paths[grepl("\\.parquet$", paths)][1]

  master    <- arrow::read_parquet(pq(charity_master_path))
  dgr_cnt   <- arrow::read_parquet(pq(dgr_counts_path))
  anc_ts    <- arrow::read_parquet(pq(ancillary_ts_path))
  panel     <- arrow::read_parquet(pq(panel_path))
  gap       <- arrow::read_parquet(pq(gap_path))
  scenarios <- arrow::read_parquet(pq(scenarios_path))
  exposure  <- arrow::read_parquet(pq(exposure_path))

  checks <- list()
  add <- function(name, value, expected, pass, note = "") {
    checks[[length(checks) + 1]] <<- dplyr::tibble(
      check = name, value = as.character(value),
      expected = as.character(expected),
      status = ifelse(pass, "PASS", "FAIL"), note = note
    )
  }

  # ---- charity_master ------------------------------------------------------
  n_master  <- nrow(master)
  n_dgr     <- sum(master$has_dgr)
  join_rate <- n_dgr / n_master
  # ACNC allows charities to withhold their ABN; those rows have NA and are
  # excluded from the uniqueness test (they're mostly PAFs, reported below).
  abns_present <- master$abn[!is.na(master$abn)]
  add("charity_master: ABN uniqueness (non-NA)",
      sum(duplicated(abns_present)), "0 duplicates",
      sum(duplicated(abns_present)) == 0)
  add("charity_master: rows with withheld (NA) ABN",
      sum(is.na(master$abn)), "< 1,000",
      sum(is.na(master$abn)) < 1000,
      "ACNC-withheld ABNs; mostly private ancillary funds")
  add("charity_master: DGR join rate",
      sprintf("%.1f%% (%s of %s)", 100 * join_rate,
              format(n_dgr, big.mark = ","), format(n_master, big.mark = ",")),
      "~50% (40-60%)",
      join_rate >= 0.40 && join_rate <= 0.60,
      "Share of ACNC-registered charities with DGR endorsement via ABR API")
  add("charity_master: provisional ancillary flag",
      sum(master$is_ancillary_provisional), "> 0 and < 1,000",
      sum(master$is_ancillary_provisional) > 0 &&
        sum(master$is_ancillary_provisional) < 1000,
      "Name match on 'ancillary'; see docs/abr_dgr_item_findings.md")

  # Definitive ancillary flag from DGR listing (is NA when listing unavailable)
  if ("is_ancillary" %in% names(master) && any(!is.na(master$is_ancillary))) {
    n_ancillary <- sum(master$is_ancillary, na.rm = TRUE)
    add("charity_master: definitive ancillary flag (is_ancillary)",
        n_ancillary, "> 500 and < 5,000",
        n_ancillary > 500 && n_ancillary < 5000,
        paste0(
          "Item 2 from DGR listing; ~3,600 PAF+PuAF total (ATO ts24). ",
          "Only ACNC-registered, ABN-disclosed funds join — wide bound expected."
        ))

    known_items <- c(1L, 2L, 4L)
    unknown_items <- unique(master$dgr_item_number[
      !is.na(master$dgr_item_number) & !(master$dgr_item_number %in% known_items)
    ])
    add("charity_master: dgr_item_number values in known set (1, 2, 4)",
        if (length(unknown_items) == 0) "all known" else paste(unknown_items, collapse = ", "),
        "no unknown values",
        length(unknown_items) == 0,
        "Known DGR item numbers: 1 (doing DGR), 2 (ancillary fund), 4 (overseas aid)")
  } else {
    cli::cli_alert_info(
      "DGR listing not available; skipping is_ancillary and dgr_item_number checks."
    )
  }

  # ---- dgr_counts_by_type vs ATO Table 3 -----------------------------------
  # Anchor: ATO Taxation Statistics 2023-24 charities Table 3 total DGR
  # endorsements. The ingest checksums categories against the Total row, so
  # here we sanity-check the total magnitude and category count.
  total_endorsements <- sum(dgr_cnt$n)
  add("dgr_counts_by_type: total endorsements",
      format(total_endorsements, big.mark = ","), "30,000-40,000 (ts24 ~34,197)",
      total_endorsements > 30000 && total_endorsements < 40000)
  add("dgr_counts_by_type: category rows",
      nrow(dgr_cnt), "31", nrow(dgr_cnt) == 31)
  # Context only: register-joined DGR charities vs ATO endorsement count.
  # These measure different things (endorsements include non-charity funds;
  # a charity can hold multiple endorsements), so no pass/fail.
  cli::cli_alert_info(paste0(
    "Context: ", format(n_dgr, big.mark = ","),
    " DGR charities on register vs ",
    format(total_endorsements, big.mark = ","),
    " ATO endorsements (different units; not directly comparable)"
  ))

  # ---- ancillary_funds_timeseries anchors (ATO ts24, 2022-23) --------------
  anchor <- function(year, type, col, expected, tol = 0.005) {
    row <- anc_ts[anc_ts$income_year == year & anc_ts$fund_type == type, ]
    val <- if (nrow(row) == 1) row[[col]] else NA_real_
    ok  <- !is.na(val) && abs(val - expected) / expected <= tol
    add(paste0("ancillary_ts: ", year, " ", type, " ", col),
        format(val, big.mark = ","), format(expected, big.mark = ","), ok)
  }
  anchor("2022-23", "PAF",  "distributions_made", 799342610)
  anchor("2022-23", "PuAF", "distributions_made", 487476097)
  anchor("2022-23", "PAF",  "n_funds", 2196)
  anchor("2022-23", "PuAF", "n_funds", 1445)

  # ---- charity_financials_panel vs ACNC published counts -------------------
  yr_counts <- panel |>
    dplyr::count(ais_year, name = "n_rows") |>
    dplyr::arrange(ais_year)
  cli::cli_alert_info("AIS panel rows by year: {paste(yr_counts$ais_year, yr_counts$n_rows, sep = '=', collapse = ', ')}")
  # ACNC publishes ~52.6k AIS lodgments for 2023 and ~53.6k for 2024.
  panel_anchor <- function(year, expected, tol = 0.05) {
    n <- yr_counts$n_rows[yr_counts$ais_year == year]
    n <- if (length(n) == 1) n else NA_integer_
    ok <- !is.na(n) && abs(n - expected) / expected <= tol
    add(paste0("panel: rows in ", year),
        format(n, big.mark = ","),
        paste0("~", format(expected, big.mark = ","), " (±5%)"), ok)
  }
  panel_anchor(2023, 52600)
  panel_anchor(2024, 53600)

  dup_by_year <- panel |>
    dplyr::group_by(ais_year) |>
    dplyr::summarise(dups = sum(duplicated(abn)), .groups = "drop")
  add("panel: duplicate ABNs within vintage",
      paste(dup_by_year$ais_year, dup_by_year$dups, sep = "=", collapse = ", "),
      "<= 2 per vintage (known ACNC source dups)",
      all(dup_by_year$dups <= 2))

  # ---- dgr_gap_analysis (Layer 2 handoff) ----------------------------------
  # Check that ancillary funds (both definitive and provisional) are excluded.
  n_ancillary_in_gap <- sum(
    gap$abn %in% master$abn[
      dplyr::coalesce(master$is_ancillary, FALSE) | master$is_ancillary_provisional
    ]
  )
  add("gap_analysis: no ancillary funds included",
      n_ancillary_in_gap,
      "0 rows",
      n_ancillary_in_gap == 0)
  dd_bad <- sum(!is.na(gap$donation_dependence) &
                  (gap$donation_dependence < 0 | gap$donation_dependence > 1.5))
  add("gap_analysis: donation_dependence in plausible range",
      paste0(dd_bad, " rows outside [0, 1.5]"), "< 1% of rows",
      dd_bad < 0.01 * nrow(gap),
      "Values slightly > 1 possible when donations exceed reported gross income")
  join_cov <- nrow(gap) / nrow(panel)
  add("gap_analysis: panel join coverage",
      sprintf("%.1f%%", 100 * join_cov), "> 90% of panel rows",
      join_cov > 0.90,
      "Rows lost to NA/withheld ABNs and ancillary exclusion")

  # ---- reform_scenarios (Layer 1) ------------------------------------------
  add("scenarios: 4 subtypes x 3 bases",
      nrow(scenarios), "12 rows", nrow(scenarios) == 12)
  pool_expected <- sum(anc_ts$distributions_made[
    anc_ts$income_year == max(anc_ts$income_year)], na.rm = TRUE)
  add("scenarios: pool matches ancillary_ts latest year",
      format(unique(scenarios$pool_total), big.mark = ","),
      format(pool_expected, big.mark = ","),
      all(scenarios$pool_total == pool_expected))
  by_basis <- tapply(scenarios$share_of_pool, scenarios$basis, sum)
  add("scenarios: cohort shares sum well below 1 per basis",
      paste(names(by_basis), sprintf("%.3f", by_basis), sep = "=", collapse = ", "),
      "each < 0.10",
      all(by_basis < 0.10),
      "Cohorts are a small slice of the expanded eligible base")
  dollars_ok <- all(abs(scenarios$annual_dollars -
                          scenarios$share_of_pool * scenarios$pool_total) < 1)
  add("scenarios: dollars = share x pool", dollars_ok, "TRUE", dollars_ok)

  # ---- dgr_incumbent_exposure (B2) -----------------------------------------
  add("exposure: all 4 subtypes present",
      length(unique(exposure$subtype)), "4",
      length(unique(exposure$subtype)) == 4)
  exp_ok <- all(exposure$n_highly_exposed <= exposure$n_incumbents)
  add("exposure: highly-exposed <= incumbents in every row", exp_ok, "TRUE", exp_ok)

  # ---- report --------------------------------------------------------------
  report <- dplyr::bind_rows(checks)
  n_fail <- sum(report$status == "FAIL")
  for (i in seq_len(nrow(report))) {
    fn <- if (report$status[i] == "PASS") cli::cli_alert_success else cli::cli_alert_danger
    fn("{report$check[i]}: {report$value[i]} (expected {report$expected[i]})")
  }
  if (n_fail > 0) {
    cli::cli_warn("{n_fail} validation check{?s} FAILED — review before using outputs.")
  } else {
    cli::cli_alert_success("All {nrow(report)} validation checks passed.")
  }
  report
}
