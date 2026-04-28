#' Ingest the ABN Lookup DGR endorsements file.
#'
#' Source: https://data.gov.au/data/dataset/deductible-gift-recipients-bulk-extract
#'         (or equivalent — check ABR/ABN Lookup bulk data page)
#' Format: typically a delimited or fixed-width text file listing every entity
#'         with DGR endorsement, plus the DGR item type and effective dates.
#' Update cadence: weekly.
#'
#' VERIFY ON FIRST RUN:
#'   - Current published format. The historical fixed-width spec is on the ABR
#'     site; recent releases have shipped as CSV. Open the file and confirm.
#'   - Whether each ABN has multiple rows (one per endorsement category) or
#'     a single row with concatenated categories. The ingestion below assumes
#'     long format (one row per ABN-endorsement pair).

ABN_DGR_URL <- "https://data.gov.au/data/dataset/PLACEHOLDER/resource/PLACEHOLDER/download/dgr-bulk-extract.csv"

download_abn_dgr <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "abn_dgr",
                   sprintf("abn_dgr_%s.csv", today_stamp()))
  download_if_missing(ABN_DGR_URL, dest, force = force)
}

ingest_abn_dgr <- function(raw_file, processed_dir) {

  # If the file is fixed-width, swap to readr::read_fwf() with positions
  # taken from the published spec. Until then, attempt CSV.
  raw <- readr::read_csv(raw_file, show_col_types = FALSE) |>
    janitor::clean_names()

  # Expected (verify): abn, entity_name, dgr_item_number, dgr_item_description,
  # endorsement_from, endorsement_to
  cleaned <- raw |>
    dplyr::mutate(
      abn = stringr::str_remove_all(as.character(abn), "[^0-9]"),
      endorsement_from = suppressWarnings(lubridate::ymd(endorsement_from)),
      endorsement_to   = suppressWarnings(lubridate::ymd(endorsement_to)),
      is_currently_endorsed = is.na(endorsement_to) |
                              endorsement_to >= Sys.Date(),
      ingestion_date = Sys.Date(),
      source_file = basename(raw_file)
    )

  out <- file.path(processed_dir, "abn_dgr.parquet")
  write_parquet_safely(cleaned, out)
}
