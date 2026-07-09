#' Ingest the ACNC Annual Information Statement (AIS) financial data.
#'
#' Source: data.gov.au, one dataset per AIS reporting year, slugs like
#'   "acnc-2023-annual-information-statement-ais-data".
#' Format: CSV per AIS reporting year. Each row is a charity-year.
#' Update cadence: annual, with a long lag (most recent typically ~18 months
#'                 behind reporting year end).
#'
#' Resource URLs are resolved at download time via the data.gov.au CKAN API
#' (package_show on the year slug, falling back to package_search), so new
#' vintages are added by appending to AIS_YEARS — no hardcoded links.
#'
#' Ingestion: ingest_ais_financials_panel() — explicit, mapping-driven
#' harmonisation of the financial fields via lookups/ais_column_mapping.csv
#' (one row per vintage x column, raw header -> harmonised name). Errors
#' loudly if a mapped column is missing from a vintage, if a vintage has no
#' mapping, or if vintages disagree on the harmonised column set.
#' -> processed/ais_financials_panel.parquet, keyed by abn x ais_year.

AIS_YEARS <- c(2021, 2022, 2023, 2024)

# ---- CKAN resolution --------------------------------------------------------

CKAN_API_BASE <- "https://data.gov.au/data/api/3/action"

#' Perform a CKAN API GET with the browser User-Agent (see download_if_missing).
ckan_api <- function(action, params) {
  req <- httr2::request(CKAN_API_BASE) |>
    httr2::req_url_path_append(action) |>
    httr2::req_url_query(!!!params) |>
    httr2::req_user_agent(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
    ) |>
    httr2::req_timeout(60) |>
    httr2::req_retry(max_tries = 3)
  httr2::resp_body_json(httr2::req_perform(req))
}

#' Resolve the main AIS CSV resource URL for a given year via the CKAN API.
#'
#' Tries package_show on the conventional slug first; falls back to
#' package_search. Picks the CSV resource whose URL matches
#' "datadotgov_ais<yy>.csv" (excludes the programs and group-members files).
resolve_ais_csv_url <- function(year) {
  yy       <- substr(as.character(year), 3, 4)
  file_pat <- sprintf("datadotgov_ais%s\\.csv$", yy)

  pick_resource <- function(pkg) {
    for (res in pkg$resources) {
      if (grepl(file_pat, res$url, ignore.case = TRUE)) return(res$url)
    }
    NULL
  }

  slug <- sprintf("acnc-%s-annual-information-statement-ais-data", year)
  url  <- tryCatch(
    pick_resource(ckan_api("package_show", list(id = slug))$result),
    error = function(e) NULL
  )
  if (!is.null(url)) return(url)

  cli::cli_alert_warning(
    "package_show failed for {.val {slug}}; falling back to package_search"
  )
  search <- ckan_api("package_search", list(
    q    = sprintf("acnc %s annual information statement", year),
    rows = 10
  ))
  for (pkg in search$result$results) {
    url <- pick_resource(pkg)
    if (!is.null(url)) return(url)
  }
  cli::cli_abort(c(
    "Could not resolve an AIS CSV resource for {year} via the CKAN API.",
    "i" = "Tried package_show on {.val {slug}} and package_search.",
    "i" = "Check https://data.gov.au/data/dataset?q=acnc+{year}+ais manually."
  ))
}

# ---- Download ---------------------------------------------------------------

#' Download the AIS CSV for each year in AIS_YEARS.
#'
#' If a dated raw file for a year already exists (any date stamp), it is
#' reused and the CKAN API is not queried — use force = TRUE (or
#' scripts/refresh_sources.R) to fetch fresh copies.
download_acnc_ais <- function(raw_dir, force = FALSE, years = AIS_YEARS) {
  ais_dir <- file.path(raw_dir, "acnc_ais")
  dests <- vapply(years, function(yr) {
    existing <- if (fs::dir_exists(ais_dir)) {
      fs::dir_ls(ais_dir, regexp = sprintf("acnc_ais_%s_\\d{8}\\.csv$", yr))
    } else character(0)
    if (length(existing) > 0 && !force) {
      dest <- as.character(sort(existing)[length(existing)])
      cli::cli_alert_info("Using cached {.path {dest}}")
      return(dest)
    }
    dest <- raw_path(raw_dir, "acnc_ais",
                     sprintf("acnc_ais_%s_%s.csv", yr, today_stamp()))
    download_if_missing(resolve_ais_csv_url(yr), dest, force = force)
  }, character(1))
  unname(dests)
}

# ---- Ingestion: mapping-driven financials panel ------------------------------

#' Build the harmonised AIS financials panel from raw vintage CSVs.
#'
#' Every column is selected via lookups/ais_column_mapping.csv — nothing is
#' inferred. Hard failures (abort):
#'   - a vintage present in raw_files has no rows in the mapping
#'   - a mapped raw_column is missing from that vintage's CSV header
#'   - vintages map to different harmonised column sets
#' Loud warnings:
#'   - numeric coercion produces new NAs (values that weren't numbers)
#'   - duplicate ABNs within a vintage (group/collective reporting)
ingest_ais_financials_panel <- function(raw_files, mapping_file, processed_dir) {
  mapping  <- readr::read_csv(mapping_file, show_col_types = FALSE)
  required <- c("ais_year", "raw_column", "harmonised_column")
  if (!all(required %in% names(mapping))) {
    cli::cli_abort("Mapping file {.path {mapping_file}} must have columns: {required}")
  }

  # Vintages must agree on the harmonised column set.
  sets <- split(mapping$harmonised_column, mapping$ais_year)
  ref  <- sort(sets[[1]])
  for (yr in names(sets)) {
    if (!identical(sort(sets[[yr]]), ref)) {
      diff <- setdiff(union(ref, sets[[yr]]), intersect(ref, sets[[yr]]))
      cli::cli_abort(c(
        "Harmonised column sets differ between mapping vintages.",
        "i" = "Vintage {yr}: {diff} not shared with vintage {names(sets)[1]}."
      ))
    }
  }

  read_one <- function(path) {
    yr  <- as.integer(stringr::str_extract(basename(path), "(?<=ais_)\\d{4}"))
    map <- mapping[mapping$ais_year == yr, ]
    if (nrow(map) == 0) {
      cli::cli_abort(c(
        "No column mapping for AIS vintage {yr}.",
        "i" = "Add rows to {.path {mapping_file}} after inspecting the file header."
      ))
    }

    hdr     <- names(readr::read_csv(path, n_max = 0, show_col_types = FALSE))
    missing <- setdiff(map$raw_column, hdr)
    if (length(missing) > 0) {
      cli::cli_abort(c(
        "AIS {yr}: mapped column{?s} missing from {.path {path}}: {.val {missing}}",
        "i" = "The ACNC has likely changed the schema. Update {.path {mapping_file}}."
      ))
    }

    df <- readr::read_csv(path, col_select = dplyr::all_of(map$raw_column),
                          col_types = readr::cols(.default = readr::col_character()))
    names(df) <- map$harmonised_column[match(names(df), map$raw_column)]

    df$abn <- stringr::str_remove_all(df$abn, "[^0-9]")

    value_cols <- setdiff(names(df), "abn")
    for (col in value_cols) {
      raw_vals <- df[[col]]
      num      <- suppressWarnings(as.numeric(gsub(",", "", raw_vals)))
      coerced  <- sum(!is.na(raw_vals) & is.na(num))
      if (coerced > 0) {
        cli::cli_alert_warning(
          "AIS {yr}: {coerced} non-numeric value{?s} in {.field {col}} coerced to NA"
        )
      }
      df[[col]] <- num
    }

    n_dupes <- sum(duplicated(df$abn))
    if (n_dupes > 0) {
      cli::cli_alert_warning("AIS {yr}: {n_dupes} duplicate ABN{?s} within vintage")
    }

    df$ais_year <- yr
    df
  }

  panel <- dplyr::bind_rows(lapply(raw_files, read_one)) |>
    dplyr::arrange(ais_year, abn) |>
    dplyr::relocate(abn, ais_year)
  panel$ingestion_date <- Sys.Date()

  counts <- table(panel$ais_year)
  cli::cli_alert_info(
    "AIS financials panel: {nrow(panel)} rows ({paste(names(counts), '=', counts, collapse = ', ')})"
  )

  out <- file.path(processed_dir, "ais_financials_panel.parquet")
  write_parquet_safely(panel, out)
}
