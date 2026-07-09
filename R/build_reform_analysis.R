#' Reform analysis outputs (Layer 1 scenarios, incumbent exposure, Layer 2
#' handoff dataset).
#'
#' Implements the two-layer reform benefit model:
#'   Layer 1 (redistribution): the annual PAF/PuAF distribution pool is legally
#'     restricted to DGRs. Scenarios estimate the share newly-eligible target
#'     cohorts might access under reform.
#'   Layer 2 (pie growth): owned by another analyst; build_dgr_gap_analysis()
#'     produces the analysis-ready dataset they start from.
#'   B2 (losers): descriptive exposure profile of incumbent DGR charities
#'     competing in the same donor markets as the target cohorts.
#'
#' All dollar outputs are scenario ranges, not point estimates. See
#' docs/methodology.md ("Distributional analysis") for assumptions.

# Maps each target subtype to the ACNC purpose boolean used as its donor-market
# proxy when identifying incumbent DGR competitors (B2).
SUBTYPE_PURPOSE_PROXY <- c(
  neighbourhood_house   = "advancing_social_or_public_welfare",
  disaster_preparedness = "advancing_security_or_safety_of_australia_or_australian_public",
  injury_prevention     = "advancing_health",
  human_rights          = "promoting_or_protecting_human_rights"
)

# ---- Layer 2 handoff: dgr_gap_analysis --------------------------------------

#' Analysis-ready charity-year dataset for the DGR vs non-DGR donations gap.
#'
#' One row per charity x AIS year: harmonised financials joined to DGR status,
#' size, state, target subtype(s), and the purpose booleans needed to build
#' size x sector strata. Charities flagged as provisional ancillary funds are
#' excluded — they are grant-makers, not donation-seekers, and would
#' contaminate a donations-gap comparison.
build_dgr_gap_analysis <- function(charity_master_path, panel_path,
                                   subtypes_path, analytical_dir) {
  pq <- function(paths) paths[grepl("\\.parquet$", paths)][1]

  master <- arrow::read_parquet(pq(charity_master_path)) |>
    dplyr::filter(!is.na(abn), !is_ancillary_provisional) |>
    dplyr::distinct(abn, .keep_all = TRUE) |>
    dplyr::select(abn, charity_legal_name, charity_size, state,
                  has_dgr, dgr_endorsed_from,
                  dplyr::all_of(unname(SUBTYPE_PURPOSE_PROXY)))

  subtypes <- arrow::read_parquet(pq(subtypes_path)) |>
    dplyr::filter(!is.na(abn)) |>
    dplyr::distinct(abn, subtype) |>
    dplyr::group_by(abn) |>
    dplyr::summarise(target_subtype = paste(sort(subtype), collapse = ";"),
                     .groups = "drop")

  panel <- arrow::read_parquet(pq(panel_path))

  out_df <- panel |>
    dplyr::inner_join(master, by = "abn") |>
    dplyr::left_join(subtypes, by = "abn") |>
    dplyr::mutate(
      donation_dependence = dplyr::if_else(
        !is.na(total_gross_income) & total_gross_income > 0,
        donations_and_bequests / total_gross_income,
        NA_real_
      )
    )

  n_sub <- sum(!is.na(out_df$target_subtype) & out_df$ais_year == max(out_df$ais_year))
  cli::cli_alert_info(
    "dgr_gap_analysis: {nrow(out_df)} charity-year rows; {n_sub} target-cohort rows in latest year"
  )

  out <- file.path(analytical_dir, "dgr_gap_analysis.parquet")
  write_outputs(out_df, out)
}

# ---- Layer 1: reform_scenarios ----------------------------------------------

#' Scenario estimates of the ancillary-fund pool accessible to newly-eligible
#' target cohorts under DGR reform.
#'
#' Pool = latest-year PAF + PuAF distributions (legally restricted to DGRs).
#' Under reform, funders can allocate across an expanded eligible base. Each
#' scenario is a mechanical allocation basis applied to that base:
#'   revenue_share   — allocation proportional to total income
#'   donations_share — proportional to donations attracted, a proxy for
#'                     demonstrated fundability
#'   count_share     — equal per charity, favouring the many small
#'                     newly-eligible organisations
#' The three bases are alternative assumptions, not an ordered low/high set:
#' which is largest depends on the cohort's size and fundraising profile.
#' Report results as the min-max range across bases.
#' Only non-DGR cohort members count as beneficiaries (leakage-adjusted).
#' These are access scenarios, not predicted flows.
build_reform_scenarios <- function(gap_path, ancillary_ts_path, analytical_dir) {
  pq  <- function(paths) paths[grepl("\\.parquet$", paths)][1]
  gap <- arrow::read_parquet(pq(gap_path))
  anc <- arrow::read_parquet(pq(ancillary_ts_path))

  latest_fy <- max(anc$income_year)
  pool <- sum(anc$distributions_made[anc$income_year == latest_fy], na.rm = TRUE)
  cli::cli_alert_info(
    "Ancillary pool {latest_fy}: {format(round(pool / 1e6), big.mark = ',')}m AUD"
  )

  # Expanded eligible base: every charity with financials in the latest AIS
  # year (current DGRs + all newly eligible under full reform).
  latest <- gap |>
    dplyr::filter(ais_year == max(ais_year)) |>
    dplyr::mutate(
      revenue   = pmax(dplyr::coalesce(total_gross_income, 0), 0),
      donations = pmax(dplyr::coalesce(donations_and_bequests, 0), 0)
    )

  base_revenue   <- sum(latest$revenue)
  base_donations <- sum(latest$donations)
  base_count     <- nrow(latest)

  subtypes <- sort(unique(unlist(strsplit(
    latest$target_subtype[!is.na(latest$target_subtype)], ";", fixed = TRUE
  ))))

  rows <- lapply(subtypes, function(st) {
    members <- latest |>
      dplyr::filter(!is.na(target_subtype),
                    stringr::str_detect(target_subtype, stringr::fixed(st)))
    newly_eligible <- members |> dplyr::filter(!has_dgr)

    shares <- c(
      revenue_share   = sum(newly_eligible$revenue)   / base_revenue,
      donations_share = sum(newly_eligible$donations) / base_donations,
      count_share     = nrow(newly_eligible)          / base_count
    )
    dplyr::tibble(
      subtype             = st,
      n_cohort            = nrow(members),
      n_newly_eligible    = nrow(newly_eligible),
      pct_already_dgr     = round(100 * mean(members$has_dgr), 1),
      basis               = names(shares),
      share_of_pool       = unname(shares),
      annual_dollars      = unname(shares) * pool,
      pool_year           = latest_fy,
      pool_total          = pool
    )
  })

  out_df <- dplyr::bind_rows(rows) |>
    dplyr::mutate(ingestion_date = Sys.Date())

  for (st in subtypes) {
    d <- out_df[out_df$subtype == st, ]
    cli::cli_alert_info(paste0(
      st, ": ", d$n_newly_eligible[1], " newly eligible; ",
      paste0(d$basis, " $", format(round(d$annual_dollars / 1e6, 1)), "m",
             collapse = " / ")
    ))
  }

  out <- file.path(analytical_dir, "reform_scenarios.parquet")
  write_outputs(out_df, out)
}

# ---- B2: dgr_incumbent_exposure ---------------------------------------------

#' Descriptive exposure profile of incumbent DGR charities competing in the
#' same donor markets as the newly-eligible target cohorts.
#'
#' For each subtype, incumbents are DGR charities sharing the cohort's ACNC
#' purpose proxy (SUBTYPE_PURPOSE_PROXY), profiled by size band on donation
#' dependence (donations / total gross income, latest AIS year). Highly
#' donation-dependent incumbents in overlapping markets are most exposed if
#' ancillary distributions and donor dollars partially redistribute.
#' Note: for human_rights the purpose proxy IS the cohort definition, so
#' incumbents = DGR cohort members (they compete with the non-DGR remainder).
#' Actual losses cannot be modelled from public data; under a pure
#' redistribution assumption, cohort gains in reform_scenarios bound total
#' incumbent losses.
build_incumbent_exposure <- function(gap_path, analytical_dir) {
  pq  <- function(paths) paths[grepl("\\.parquet$", paths)][1]
  gap <- arrow::read_parquet(pq(gap_path))

  latest <- gap |> dplyr::filter(ais_year == max(ais_year))

  rows <- lapply(names(SUBTYPE_PURPOSE_PROXY), function(st) {
    proxy_col <- SUBTYPE_PURPOSE_PROXY[[st]]
    is_member <- !is.na(latest$target_subtype) &
      stringr::str_detect(latest$target_subtype, stringr::fixed(st))
    # Exclude cohort members — except where the proxy IS the cohort definition
    # (human_rights), where DGR members are exactly the incumbent competitors.
    exclude_members <- proxy_col != "promoting_or_protecting_human_rights"
    incumbents <- latest |>
      dplyr::filter(
        has_dgr,
        !is.na(.data[[proxy_col]]) & .data[[proxy_col]] == "Y",
        if (exclude_members) !is_member else TRUE
      )

    incumbents |>
      dplyr::group_by(charity_size) |>
      dplyr::summarise(
        n_incumbents              = dplyr::n(),
        total_donations           = sum(donations_and_bequests, na.rm = TRUE),
        median_donation_dependence = stats::median(donation_dependence, na.rm = TRUE),
        n_highly_exposed          = sum(donation_dependence > 0.5, na.rm = TRUE),
        .groups = "drop"
      ) |>
      dplyr::mutate(subtype = st, purpose_proxy = proxy_col, .before = 1)
  })

  out_df <- dplyr::bind_rows(rows) |>
    dplyr::mutate(ingestion_date = Sys.Date())

  tot <- out_df |>
    dplyr::group_by(subtype) |>
    dplyr::summarise(n = sum(n_incumbents), hx = sum(n_highly_exposed),
                     .groups = "drop")
  for (i in seq_len(nrow(tot))) {
    cli::cli_alert_info(
      "{tot$subtype[i]}: {tot$n[i]} incumbent DGR competitors, {tot$hx[i]} highly donation-dependent (>50%)"
    )
  }

  out <- file.path(analytical_dir, "dgr_incumbent_exposure.parquet")
  write_outputs(out_df, out)
}
