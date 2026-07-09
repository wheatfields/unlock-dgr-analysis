#' Ingest ATO Taxation Statistics — Charities tables (DGR types and
#' ancillary funds).
#'
#' Edition: 2023-24 (ts24). Update ATO_CHARITIES_* constants when a new
#' edition is published; raw filenames are edition-stamped so multiple
#' editions can coexist in data/raw/ato_stats/.
#'
#' Table 3  (ts24charities03deductiblegiftrecipients.xlsx):
#'   Sheet "Table 3". Row 1 = title, row 2 = header ("DGR type1,2" / "no."),
#'   rows 3+ = one row per DGR type, final row = "Total". Counts are of
#'   organisations with active DGR status as at the edition's snapshot date
#'   (31 October 2025 for ts24). Category labels carry footnote superscripts
#'   that arrive as trailing digits (e.g. "Other organisations2") — stripped
#'   at ingestion.
#'
#' Table 4  (ts24charities04privatepublicancillaryfunds.xlsx):
#'   Sheets "Table 4A" (2016-17 to 2023-24) and "Table 4B" (2000-01 to
#'   2015-16). The two sheets do NOT share a row layout (4B uses different
#'   distribution categories and the label "Total number of PubAFs"), so
#'   rows are located by label matching on column 1 rather than fixed
#'   indices. Year labels live in row 2; column 2 is the unit. PubAF data
#'   before 2016-17 is published as "na" and dropped.
#'
#' Source: ATO Taxation Statistics 2023-24, data.gov.au dataset
#'   taxation-statistics-2023-24 (faea4485-f407-457d-97f8-3f0822ccd654).

ATO_CHARITIES_EDITION <- "2023-24"

ATO_CHARITIES_TABLE3_URL <- "https://data.gov.au/data/dataset/faea4485-f407-457d-97f8-3f0822ccd654/resource/36488f55-4b02-4d52-8093-8c4c54b44578/download/ts24charities03deductiblegiftrecipients.xlsx"
ATO_CHARITIES_TABLE4_URL <- "https://data.gov.au/data/dataset/faea4485-f407-457d-97f8-3f0822ccd654/resource/ee81a94a-bd54-44af-ad19-5d2ae804e949/download/ts24charities04privatepublicancillaryfunds.xlsx"

# Edition tag for filenames: "2023-24" -> "ts24"
ato_charities_edition_tag <- function() {
  sprintf("ts%s", substr(ATO_CHARITIES_EDITION, 6, 7))
}

# ---- Downloads --------------------------------------------------------------

download_ato_charities_table3 <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "ato_stats",
                   sprintf("ato_charities_table3_%s_%s.xlsx",
                           ato_charities_edition_tag(), today_stamp()))
  download_if_missing(ATO_CHARITIES_TABLE3_URL, dest, force = force)
}

download_ato_charities_table4 <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "ato_stats",
                   sprintf("ato_charities_table4_%s_%s.xlsx",
                           ato_charities_edition_tag(), today_stamp()))
  download_if_missing(ATO_CHARITIES_TABLE4_URL, dest, force = force)
}

# ---- Table 3: DGR counts by type -------------------------------------------

#' Parse charities Table 3 into one row per DGR category.
#'
#' The "Total" row is excluded from the output but used as a checksum:
#' aborts if the component sum differs from the published total by more
#' than 1% (allows for privacy suppression noted in the sheet).
ingest_ato_charities_table3 <- function(raw_file, processed_dir) {
  raw <- readxl::read_excel(raw_file, sheet = "Table 3", skip = 2,
                            col_names = FALSE)
  if (ncol(raw) != 2) {
    cli::cli_abort(
      "Expected 2 columns in charities Table 3, found {ncol(raw)} — layout changed?"
    )
  }
  names(raw) <- c("dgr_category", "n")

  parsed <- data.frame(
    dgr_category = trimws(sub("[0-9, ]+$", "", trimws(as.character(raw$dgr_category)))),
    n            = suppressWarnings(as.integer(raw$n)),
    stringsAsFactors = FALSE
  )
  parsed <- dplyr::filter(parsed, !is.na(n), nchar(dgr_category) > 0)

  is_total <- tolower(parsed$dgr_category) == "total"
  if (sum(is_total) != 1) {
    cli::cli_abort("Expected exactly 1 'Total' row in charities Table 3, found {sum(is_total)}")
  }
  published_total <- parsed$n[is_total]
  component_sum   <- sum(parsed$n[!is_total])
  if (abs(component_sum - published_total) / published_total > 0.01) {
    cli::cli_abort(c(
      "Charities Table 3 checksum failed.",
      "i" = "Sum of categories: {component_sum}; published total: {published_total}"
    ))
  }
  cli::cli_alert_info(
    "Table 3: {sum(!is_total)} DGR categories, total {published_total} endorsements"
  )

  result <- parsed[!is_total, ]
  result$edition        <- ATO_CHARITIES_EDITION
  result$ingestion_date <- Sys.Date()
  result$source_file    <- basename(raw_file)

  out <- file.path(processed_dir, "ato_dgr_counts_by_type.parquet")
  write_parquet_safely(result, out)
}

# ---- Table 4: ancillary funds time series -----------------------------------

#' Parse one ancillary funds sheet (Table 4A or 4B) by label matching.
#'
#' Returns a wide data frame: one row per income_year x fund_type with
#' funds_approved, n_funds, donations_received, distributions_made,
#' net_assets. Rows where every metric is NA (e.g. PubAFs before 2016-17,
#' published as "na") are dropped.
parse_ancillary_ts_sheet <- function(raw_file, sheet) {
  raw    <- readxl::read_excel(raw_file, sheet = sheet, col_names = FALSE)
  labels <- trimws(as.character(raw[[1]]))

  # Year labels: row 2, from column 3. Normalise Unicode dashes.
  year_row <- as.character(unlist(raw[2, ]))
  year_idx <- which(grepl("\\d{4}", year_row))
  if (length(year_idx) == 0) {
    cli::cli_abort("No year labels found in row 2 of sheet {sheet} — layout changed?")
  }
  years <- stringr::str_replace_all(year_row[year_idx], "[\u2013\u2014\u2012]", "-")

  find_row <- function(pattern, after = 0) {
    hits <- which(grepl(pattern, labels, ignore.case = TRUE) &
                    seq_along(labels) > after)
    if (length(hits) == 0) {
      cli::cli_abort(
        "Sheet {sheet}: no row matching {.val {pattern}} — layout changed?"
      )
    }
    hits[1]
  }
  vals <- function(row_idx) {
    suppressWarnings(as.numeric(unlist(raw[row_idx, year_idx])))
  }

  extract_fund <- function(fund_type, approved_pat, total_pat, donations_pat,
                           dist_header_pat, assets_pat) {
    dist_header <- find_row(dist_header_pat)
    data.frame(
      income_year         = years,
      fund_type           = fund_type,
      funds_approved      = vals(find_row(approved_pat)),
      n_funds             = vals(find_row(total_pat)),
      donations_received  = vals(find_row(donations_pat)),
      distributions_made  = vals(find_row("^Total distributions made", after = dist_header)),
      net_assets          = vals(find_row(assets_pat)),
      stringsAsFactors    = FALSE
    )
  }

  paf <- extract_fund(
    "PAF",
    approved_pat    = "^Approved Private Ancillary Funds",
    total_pat       = "^Total (number of )?PAFs",
    donations_pat   = "^PAF donations received",
    dist_header_pat = "^PAF distributions made",
    assets_pat      = "^Net PAF assets"
  )
  puaf <- extract_fund(
    "PuAF",
    approved_pat    = "^Approved Public Ancillary Funds",
    total_pat       = "^Total (number of )?PubAFs",
    donations_pat   = "^PubAF donations received",
    dist_header_pat = "^PubAF distributions made",
    assets_pat      = "^Net PubAF assets"
  )

  combined <- rbind(paf, puaf)
  metric_cols <- c("funds_approved", "n_funds", "donations_received",
                   "distributions_made", "net_assets")
  keep <- rowSums(!is.na(combined[metric_cols])) > 0
  combined[keep, ]
}

#' Ingest charities Table 4 (Tables 4A + 4B) into a wide time series.
#'
#' One row per income_year x fund_type (PAF / PuAF), 2000-01 onwards.
ingest_ato_charities_table4 <- function(raw_file, processed_dir) {
  combined <- rbind(
    parse_ancillary_ts_sheet(raw_file, "Table 4A"),
    parse_ancillary_ts_sheet(raw_file, "Table 4B")
  )

  dupes <- combined |>
    dplyr::count(income_year, fund_type) |>
    dplyr::filter(n > 1)
  if (nrow(dupes) > 0) {
    cli::cli_abort(c(
      "Duplicate income_year x fund_type rows across Tables 4A/4B.",
      "i" = "Duplicated: {paste(dupes$income_year, dupes$fund_type, collapse = ', ')}"
    ))
  }

  combined <- dplyr::arrange(combined, fund_type, income_year)
  combined$edition        <- ATO_CHARITIES_EDITION
  combined$ingestion_date <- Sys.Date()
  combined$source_file    <- basename(raw_file)

  latest <- max(combined$income_year)
  for (ft in c("PAF", "PuAF")) {
    row <- combined[combined$fund_type == ft & combined$income_year == latest, ]
    if (nrow(row) == 1) {
      cli::cli_alert_info(
        "{ft} {latest}: {row$n_funds} funds, distributions ${format(row$distributions_made / 1e6, digits = 4)}m, net assets ${format(row$net_assets / 1e9, digits = 3)}B"
      )
    }
  }

  out <- file.path(processed_dir, "ato_ancillary_funds_timeseries.parquet")
  write_parquet_safely(combined, out)
}
