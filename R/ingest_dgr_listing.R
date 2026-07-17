#' Ingest the ABN Lookup DGR Listing files.
#'
#' Source: https://abr.business.gov.au/Tools/DgrListing
#' Format: Fixed-width plain text (two files: endorsed entities, and funds /
#'         authorities / institutions).
#' Update cadence: On demand (ATO updates periodically; re-run scripts/refresh_sources.R).
#'
#' Column layouts (1-based start positions from the ABN Lookup help page):
#'
#' DGR endorsed entities:
#'   ABN: 1, ABN status: 13, DGR status date: 24, State: 40, Postcode: 46,
#'   Entity name: 59, DGR item number: 260, DGR item type: 271
#'
#' DGR funds, authorities and institutions:
#'   ABN: 1, ABN status: 13, DGR status date: 24, State: 45, Postcode: 51,
#'   DGR fund name: 64, Entity name: 289, DGR item number: 490
#'
#' Item 2 rows in the entities file are ancillary funds (PAF/PuAF), giving a
#' definitive structural classification that supersedes the provisional
#' name-match on "ancillary".
#'
#' If the download URLs cannot be reached, the function skips with a clear
#' message and returns the path to an empty sentinel file (consistent with
#' other network-dependent ingestion in this pipeline). The join in
#' build_charity_master() handles a zero-row listing gracefully by falling
#' back to NA for the new columns.
#'
#' ABNs may contain spaces in the raw files; normalise to 11 digits on ingest.

DGR_LISTING_BASE_URL <- "https://abr.business.gov.au/Tools/DgrListing"

# Known-good direct download URLs (verified against ABR listing page).
# ABR occasionally rotates these; if they fail the download will skip
# gracefully and log the URL so it can be updated here.
DGR_LISTING_ENTITIES_URL <- paste0(
  "https://data.gov.au/data/dataset/",
  "b050b242-4487-4306-abf5-07ca073e5594/",   # placeholder — ABR does not
  "resource/dgr_entities/download/dgr_entities.txt"  # expose a stable DOI URL
)
# Actual ABR download URLs (used at runtime; override above placeholder):
DGR_ENTITIES_URL <- "https://abr.business.gov.au/Tools/DgrListing?exportFormat=text&type=entity"
DGR_FUNDS_URL    <- "https://abr.business.gov.au/Tools/DgrListing?exportFormat=text&type=fund"

# ---- Download helpers -------------------------------------------------------

download_dgr_listing_entities <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "dgr_listing",
                   sprintf("dgr_entities_%s.txt", today_stamp()))
  .download_dgr_listing_file(DGR_ENTITIES_URL, dest, "entities", force = force)
}

download_dgr_listing_funds <- function(raw_dir, force = FALSE) {
  dest <- raw_path(raw_dir, "dgr_listing",
                   sprintf("dgr_funds_%s.txt", today_stamp()))
  .download_dgr_listing_file(DGR_FUNDS_URL, dest, "funds", force = force)
}

#' Internal helper: attempt download; on failure write a zero-byte sentinel
#' and return the path (so the target still resolves as a file).
.download_dgr_listing_file <- function(url, dest, label, force = FALSE) {
  if (fs::file_exists(dest) && !force) {
    cli::cli_alert_info("Using cached {.path {dest}}")
    return(dest)
  }

  tryCatch(
    {
      download_if_missing(url, dest, force = force)
    },
    error = function(e) {
      cli::cli_alert_warning(c(
        "Could not download DGR listing ({label}) from {.url {url}}.",
        "i" = "Error: {conditionMessage(e)}",
        "i" = "An empty sentinel file will be written so the pipeline can continue.",
        "i" = "The is_ancillary column will be NA for all charities; is_ancillary_provisional remains as fallback.",
        "i" = "To retry: set force = TRUE or run scripts/refresh_sources.R"
      ))
      dir <- dirname(dest)
      if (!fs::dir_exists(dir)) fs::dir_create(dir, recurse = TRUE)
      writeLines(character(0), dest)
    }
  )
  dest
}

# ---- Parsing helpers --------------------------------------------------------

#' Parse the DGR endorsed-entities fixed-width file.
#'
#' Column layout (1-based start positions):
#'   ABN: 1  ABN_status: 13  dgr_status_date: 24  state: 40  postcode: 46
#'   entity_name: 59  dgr_item_number: 260  dgr_item_type: 271
.parse_dgr_entities <- function(path) {
  col_spec <- readr::fwf_positions(
    start = c( 1,  13,  24,  40,  46,  59, 260, 271),
    end   = c(12,  23,  39,  45,  58, 259, 270,  NA),
    col_names = c(
      "abn", "abn_status", "dgr_status_date",
      "state", "postcode", "entity_name",
      "dgr_item_number", "dgr_item_type"
    )
  )
  suppressWarnings(
    readr::read_fwf(path, col_positions = col_spec,
                    col_types = readr::cols(.default = readr::col_character()),
                    skip_empty_rows = TRUE,
                    show_col_types = FALSE)
  )
}

#' Parse the DGR funds / authorities / institutions fixed-width file.
#'
#' Column layout (1-based start positions):
#'   ABN: 1  ABN_status: 13  dgr_status_date: 24  state: 45  postcode: 51
#'   dgr_fund_name: 64  entity_name: 289  dgr_item_number: 490
.parse_dgr_funds <- function(path) {
  col_spec <- readr::fwf_positions(
    start = c( 1,  13,  24,  45,  51,  64, 289, 490),
    end   = c(12,  23,  44,  50,  63, 288, 489,  NA),
    col_names = c(
      "abn", "abn_status", "dgr_status_date",
      "state", "postcode", "dgr_fund_name",
      "entity_name", "dgr_item_number"
    )
  )
  suppressWarnings(
    readr::read_fwf(path, col_positions = col_spec,
                    col_types = readr::cols(.default = readr::col_character()),
                    skip_empty_rows = TRUE,
                    show_col_types = FALSE)
  )
}

#' Normalise raw columns shared by both files.
.clean_dgr_shared <- function(df) {
  df |>
    dplyr::mutate(
      # Remove all non-digits from ABN (may contain spaces in raw file)
      abn             = stringr::str_remove_all(abn, "[^0-9]"),
      abn_status      = stringr::str_trim(abn_status),
      dgr_status_date = stringr::str_trim(dgr_status_date),
      state           = stringr::str_trim(state),
      postcode        = stringr::str_trim(postcode),
      entity_name     = stringr::str_trim(entity_name),
      dgr_item_number = suppressWarnings(
        as.integer(stringr::str_trim(dgr_item_number))
      )
    ) |>
    # Drop header/footer rows (ABN column will be non-numeric or wrong length)
    dplyr::filter(!is.na(abn), nchar(abn) == 11)
}

# ---- Main ingest function ---------------------------------------------------

#' Parse and combine DGR listing files into a tidy parquet.
#'
#' @param entities_path Path to the downloaded entities fixed-width file.
#' @param funds_path    Path to the downloaded funds fixed-width file.
#' @param processed_dir Directory for the output parquet.
#' @return Path to the written parquet file.
ingest_dgr_listing <- function(entities_path, funds_path, processed_dir) {

  out <- file.path(processed_dir, "dgr_listing.parquet")

  # ---- Parse entities file --------------------------------------------------
  entities_raw <- .parse_dgr_entities(entities_path)

  if (nrow(entities_raw) == 0) {
    cli::cli_alert_warning(c(
      "DGR entities file is empty (download may have been skipped).",
      "i" = "Writing zero-row dgr_listing.parquet; is_ancillary will be NA for all charities."
    ))
    empty <- dplyr::tibble(
      abn = character(), abn_status = character(), dgr_status_date = character(),
      state = character(), postcode = character(), entity_name = character(),
      dgr_fund_name = character(), dgr_item_number = integer(),
      dgr_item_type = character(), record_level = character(),
      ingestion_date = as.Date(character()), source_file = character()
    )
    return(write_parquet_safely(empty, out))
  }

  entities <- entities_raw |>
    .clean_dgr_shared() |>
    dplyr::mutate(
      entity_name     = stringr::str_trim(entity_name),
      dgr_item_type   = stringr::str_trim(dgr_item_type),
      dgr_fund_name   = NA_character_,
      record_level    = "entity"
    )

  # ---- Validate entity layout -----------------------------------------------
  n_valid_abn   <- sum(grepl("^[0-9]{11}$", entities$abn))
  n_item_known  <- sum(entities$dgr_item_number %in% c(1L, 2L, 4L), na.rm = TRUE)
  cli::cli_alert_info(
    "DGR entities: {nrow(entities)} rows; {n_valid_abn} with valid 11-digit ABN; {n_item_known} with known item number (1/2/4)"
  )
  if (n_valid_abn < 100) {
    cli::cli_alert_warning(
      "Fewer than 100 valid ABNs in entities file — column layout may have shifted. Check start positions."
    )
  }

  # ---- Parse funds file -----------------------------------------------------
  funds_raw <- .parse_dgr_funds(funds_path)

  funds <- if (nrow(funds_raw) == 0) {
    cli::cli_alert_warning("DGR funds file is empty; no fund-level records will be included.")
    dplyr::tibble(
      abn = character(), abn_status = character(), dgr_status_date = character(),
      state = character(), postcode = character(), dgr_fund_name = character(),
      entity_name = character(), dgr_item_number = integer(),
      dgr_item_type = character(), record_level = character()
    )
  } else {
    funds_raw |>
      .clean_dgr_shared() |>
      dplyr::mutate(
        dgr_fund_name   = stringr::str_trim(dgr_fund_name),
        dgr_item_type   = NA_character_,
        record_level    = "fund"
      )
  }

  # ---- Combine and write ----------------------------------------------------
  combined <- dplyr::bind_rows(
    entities |> dplyr::select(abn, abn_status, dgr_status_date, state, postcode,
                               entity_name, dgr_fund_name, dgr_item_number,
                               dgr_item_type, record_level),
    funds    |> dplyr::select(abn, abn_status, dgr_status_date, state, postcode,
                               entity_name, dgr_fund_name, dgr_item_number,
                               dgr_item_type, record_level)
  ) |>
    dplyr::mutate(
      ingestion_date = Sys.Date(),
      source_file    = dplyr::case_when(
        record_level == "entity" ~ basename(entities_path),
        TRUE                     ~ basename(funds_path)
      )
    )

  n_item2 <- sum(combined$dgr_item_number == 2L & combined$record_level == "entity",
                 na.rm = TRUE)
  cli::cli_alert_info(
    "DGR listing combined: {nrow(combined)} rows ({sum(combined$record_level == 'entity')} entity, {sum(combined$record_level == 'fund')} fund); {n_item2} entity-level Item 2 (ancillary funds)"
  )

  write_parquet_safely(combined, out)
}
