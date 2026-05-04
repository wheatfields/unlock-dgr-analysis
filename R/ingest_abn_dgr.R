#' Look up DGR endorsement status for ACNC-registered charities via the ABR
#' Lookup web service.
#'
#' Source: https://abr.business.gov.au/ABRXMLSearch/
#' Auth:   Free GUID — register at https://abr.business.gov.au/RegisterAgreement.aspx
#'         Then add to your project .Renviron:
#'           ABR_GUID=your-guid-here
#'
#' Replaces the previous ABN bulk XML streaming approach. Instead of downloading
#' and parsing ~12 GB of ZIP files to extract ~1,500 DGR records, we look up
#' only the ~60k charity ABNs we already have from the ACNC register.
#'
#' Runtime: ~15-30 min on first run (5 concurrent requests); subsequent runs
#' are instant unless the ACNC register file has changed (targets caching).
#'
#' Note: DGR item numbers are not available via this API endpoint. The output
#' schema is: abn, has_dgr, dgr_endorsed_from, ingestion_date.

ABR_SEARCH_URL <- "https://abr.business.gov.au/ABRXMLSearch/AbrXmlSearch.asmx/SearchByABNv202001"

ingest_abn_dgr <- function(register_path, processed_dir) {
  guid <- Sys.getenv("ABR_GUID")
  if (nchar(trimws(guid)) == 0) {
    cli::cli_abort(c(
      "ABR_GUID environment variable is not set.",
      "i" = "Register for a free GUID at {.url https://abr.business.gov.au/RegisterAgreement.aspx}",
      "i" = "Then add to .Renviron: {.code ABR_GUID=your-guid-here}"
    ))
  }

  register <- arrow::read_parquet(register_path)
  abns     <- unique(register$abn)
  abns     <- abns[!is.na(abns) & nchar(abns) == 11]
  cli::cli_alert_info("Looking up {length(abns)} ABNs via ABR API")

  reqs <- lapply(abns, function(abn) {
    httr2::request(ABR_SEARCH_URL) |>
      httr2::req_url_query(
        searchString             = abn,
        includeHistoricalDetails = "N",
        authenticationGuid       = guid
      ) |>
      httr2::req_timeout(15) |>
      httr2::req_retry(max_tries = 3, backoff = ~ 2 ^ .x)
  })

  resps <- httr2::req_perform_parallel(reqs, max_active = 5, on_error = "continue",
                                       progress = TRUE)

  rows  <- vector("list", length(resps))
  n_err <- 0L

  for (i in seq_along(resps)) {
    resp <- resps[[i]]
    if (inherits(resp, "error")) { n_err <- n_err + 1L; next }
    tryCatch({
      body     <- httr2::resp_body_string(resp)
      # ABR XML uses camelCase tags: <dgrEndorsement> and <dgrFund> (not <DGR>/<DGRFund>)
      has_dgr  <- grepl("dgrEndorsement>|dgrFund>", body)
      m        <- regmatches(body, regexpr("endorsedFrom>([^<]+)<", body))
      from_raw <- if (length(m) > 0) sub("endorsedFrom>([^<]+)<", "\\1", m) else NA_character_
      rows[[i]] <- data.frame(
        abn               = abns[[i]],
        has_dgr           = has_dgr,
        dgr_endorsed_from = from_raw,
        stringsAsFactors  = FALSE
      )
    }, error = function(e) { n_err <<- n_err + 1L })
  }

  if (n_err > 0) cli::cli_alert_warning("{n_err} lookups failed and were skipped")

  rows     <- Filter(Negate(is.null), rows)
  combined <- do.call(rbind, rows)
  combined$dgr_endorsed_from <- suppressWarnings(lubridate::ymd(combined$dgr_endorsed_from))
  combined$ingestion_date    <- Sys.Date()

  cli::cli_alert_info("DGR entities found: {sum(combined$has_dgr, na.rm = TRUE)}")

  out <- file.path(processed_dir, "abn_dgr.parquet")
  write_parquet_safely(combined, out)
}
