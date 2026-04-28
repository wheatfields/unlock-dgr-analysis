#' Ingest ATO Taxation Statistics on charitable giving and QUT-ACPNS analysis.
#'
#' Sources:
#'   - ATO Taxation Statistics: https://data.gov.au/data/dataset/taxation-statistics-individuals
#'     (the 'Individuals — Selected items, by age, sex, taxable status' tables
#'      contain gift deduction figures by income range)
#'   - QUT-ACPNS giving statistics:
#'     https://research.qut.edu.au/australian-centre-for-philanthropy-and-nonprofit-studies/resources/giving-statistics/
#'
#' Format: ATO publishes Excel; QUT-ACPNS publishes PDFs/Excel summaries.
#' Update cadence: annual; ATO most recent release lags by ~18 months.
#'
#' VERIFY ON FIRST RUN:
#'   - Which ATO table contains the gift deduction series of interest.
#'   - Whether the QUT-ACPNS series is needed as a separate source or as a
#'     consistency check on the ATO numbers.
#'   - Most recent year available (per project memory: 2022-23 as of build).

# Aggregate-level data; granularity is by income band / year, not per charity.
ATO_GIFTS_URL <- "https://data.gov.au/data/dataset/PLACEHOLDER/ato-individuals-deductions.xlsx"

download_ato_stats <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "ato_stats",
                   sprintf("ato_individuals_deductions_%s.xlsx", today_stamp()))
  download_if_missing(ATO_GIFTS_URL, dest, force = force)
}

ingest_ato_stats <- function(raw_file, processed_dir) {

  # ATO publishes Excel with header rows that need skipping. The exact sheet
  # and skip count must be determined from the actual file. Placeholder logic:
  if (!requireNamespace("readxl", quietly = TRUE)) {
    cli::cli_abort("readxl is required for ATO ingestion. Install with `install.packages('readxl')`.")
  }

  sheets <- readxl::excel_sheets(raw_file)
  cli::cli_alert_info("ATO file sheets: {sheets}")

  # TODO on first run: identify the correct sheet, header row, and the columns
  # corresponding to gift deductions. Until then, read the first sheet raw.
  raw <- readxl::read_excel(raw_file, sheet = 1) |>
    janitor::clean_names() |>
    dplyr::mutate(
      ingestion_date = Sys.Date(),
      source_file = basename(raw_file)
    )

  out <- file.path(processed_dir, "ato_stats.parquet")
  write_parquet_safely(raw, out)
}
