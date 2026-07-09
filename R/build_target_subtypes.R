#' Target subtype scaffolding: human_rights, neighbourhood_house,
#' disaster_preparedness, injury_prevention.
#'
#' Assembly rules (see also lookups/target_subtype_rules.csv):
#'   - human_rights: derived directly from the ACNC register boolean
#'     "promoting or protecting human rights". No manual list, no keywords.
#'   - neighbourhood_house, disaster_preparedness, injury_prevention:
#'     UNION of (a) manually curated ABNs in data/mappings/target_subtypes.csv
#'     and (b) rule-based matches from lookups/target_subtype_rules.csv.
#'
#' NOTHING is auto-included: only rules with status == "whitelisted" in the
#' rules file are applied to the final output. Rules default to status ==
#' "candidate", which only feeds the diagnostic candidate CSVs written to
#' analysis/subtype_candidates/ for human review. To promote a rule, change
#' its status to "whitelisted" in the rules file and document the review in
#' the notes column.
#'
#' Rule types:
#'   - name_keyword: case-insensitive regex against the register's
#'     charity_legal_name.
#'   - classie_classification: exact match on the CLASSIE "Classification"
#'     column of the AIS programs datasets (any vintage). A charity matches
#'     if any of its reported programs carries the classification.

TARGET_SUBTYPES <- c("human_rights", "neighbourhood_house",
                     "disaster_preparedness", "injury_prevention")

# ---- AIS programs downloads (CLASSIE classifications) ------------------------

#' Resolve the AIS *programs* CSV resource URL for a year via the CKAN API.
#' Same strategy as resolve_ais_csv_url() but matching
#' "datadotgov_ais<yy>_programs.csv".
resolve_ais_programs_csv_url <- function(year) {
  yy       <- substr(as.character(year), 3, 4)
  file_pat <- sprintf("datadotgov_ais%s_programs\\.csv$", yy)

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
  cli::cli_abort(
    "Could not resolve an AIS programs CSV resource for {year} via the CKAN API."
  )
}

#' Download the AIS programs CSV for each year in AIS_YEARS.
download_acnc_ais_programs <- function(raw_dir, force = FALSE, years = AIS_YEARS) {
  prog_dir <- file.path(raw_dir, "acnc_ais_programs")
  dests <- vapply(years, function(yr) {
    existing <- if (fs::dir_exists(prog_dir)) {
      fs::dir_ls(prog_dir, regexp = sprintf("acnc_ais_programs_%s_\\d{8}\\.csv$", yr))
    } else character(0)
    if (length(existing) > 0 && !force) {
      dest <- as.character(sort(existing)[length(existing)])
      cli::cli_alert_info("Using cached {.path {dest}}")
      return(dest)
    }
    dest <- raw_path(raw_dir, "acnc_ais_programs",
                     sprintf("acnc_ais_programs_%s_%s.csv", yr, today_stamp()))
    download_if_missing(resolve_ais_programs_csv_url(yr), dest, force = force)
  }, character(1))
  unname(dests)
}

# ---- Shared readers ----------------------------------------------------------

#' Read abn x classification x ais_year from the AIS programs files.
read_ais_program_classifications <- function(programs_files) {
  per_year <- lapply(programs_files, function(path) {
    yr  <- as.integer(stringr::str_extract(basename(path), "(?<=programs_)\\d{4}"))
    hdr <- names(readr::read_csv(path, n_max = 0, show_col_types = FALSE))
    need <- c("ABN", "Charity Name", "Classification")
    missing <- setdiff(need, hdr)
    if (length(missing) > 0) {
      cli::cli_abort(c(
        "AIS programs {yr}: expected column{?s} missing: {.val {missing}}",
        "i" = "File: {.path {path}}"
      ))
    }
    df <- readr::read_csv(path, col_select = dplyr::all_of(need),
                          col_types = readr::cols(.default = readr::col_character()))
    names(df) <- c("abn", "charity_name", "classification")
    df$abn      <- stringr::str_remove_all(df$abn, "[^0-9]")
    df$ais_year <- yr
    df
  })
  dplyr::bind_rows(per_year)
}

# ---- Diagnostic candidate reports (human review) -----------------------------

#' Write candidate CSVs to analysis/subtype_candidates/ for human review.
#'
#' Outputs:
#'   - classie_classification_counts.csv: counts per CLASSIE classification x
#'     vintage for classifications matching disaster/emergency/injury/safety
#'     themes (broad scan, not limited to the rules file).
#'   - classie_candidates.csv: charity-level candidates for every
#'     classie_classification rule in the rules file (any status), with the
#'     matching rule_id.
#'   - name_keyword_candidates.csv: register charities matching any
#'     name_keyword rule (any status), with the matching rule_id.
#'
#' Returns the paths of the files written (targets format = "file").
report_subtype_candidates <- function(programs_files, register_path, rules_file,
                                      out_dir = "analysis/subtype_candidates") {
  if (!fs::dir_exists(out_dir)) fs::dir_create(out_dir, recurse = TRUE)
  rules <- readr::read_csv(rules_file, show_col_types = FALSE)

  programs <- read_ais_program_classifications(programs_files)
  register <- arrow::read_parquet(register_path)

  # 1. Broad diagnostic: counts per relevant classification x vintage.
  theme_pat <- paste0(
    "disaster|emergenc|injur|safety|first aid|rescue|prepared|fire|flood|",
    "storm|cyclone|lifesaving|life saving|ambulance|accident"
  )
  counts <- programs |>
    dplyr::filter(stringr::str_detect(classification,
                                      stringr::regex(theme_pat, ignore_case = TRUE))) |>
    dplyr::count(classification, ais_year, name = "n_programs") |>
    dplyr::group_by(classification) |>
    dplyr::mutate(n_charities_all_years =
                    dplyr::n_distinct(programs$abn[programs$classification ==
                                                     classification[1]])) |>
    dplyr::ungroup() |>
    tidyr_pivot_wider_years()

  counts_path <- file.path(out_dir, "classie_classification_counts.csv")
  readr::write_csv(counts, counts_path)

  # 2. Charity-level candidates for classie_classification rules (any status).
  classie_rules <- rules[rules$rule_type == "classie_classification", ]
  classie_candidates <- programs |>
    dplyr::inner_join(
      classie_rules[, c("rule_id", "subtype", "pattern", "status")],
      by = dplyr::join_by(classification == pattern)
    ) |>
    dplyr::distinct(abn, charity_name, subtype, classification, rule_id,
                    rule_status = status, ais_year) |>
    dplyr::arrange(subtype, classification, charity_name, ais_year)

  classie_path <- file.path(out_dir, "classie_candidates.csv")
  readr::write_csv(classie_candidates, classie_path)

  # 3. Name-keyword candidates from the register (any status).
  kw_rules <- rules[rules$rule_type == "name_keyword", ]
  kw_candidates <- lapply(seq_len(nrow(kw_rules)), function(i) {
    hits <- register[stringr::str_detect(
      register$charity_legal_name,
      stringr::regex(kw_rules$pattern[i], ignore_case = TRUE)
    ), c("abn", "charity_legal_name")]
    if (nrow(hits) == 0) return(NULL)
    hits$subtype     <- kw_rules$subtype[i]
    hits$rule_id     <- kw_rules$rule_id[i]
    hits$rule_status <- kw_rules$status[i]
    hits$pattern     <- kw_rules$pattern[i]
    hits
  })
  kw_candidates <- dplyr::bind_rows(kw_candidates) |>
    dplyr::distinct() |>
    dplyr::arrange(subtype, rule_id, charity_legal_name)

  kw_path <- file.path(out_dir, "name_keyword_candidates.csv")
  readr::write_csv(kw_candidates, kw_path)

  cli::cli_alert_success(
    "Subtype candidates written to {.path {out_dir}}: {nrow(classie_candidates)} CLASSIE rows, {nrow(kw_candidates)} name-keyword rows"
  )
  c(counts_path, classie_path, kw_path)
}

#' Reshape classification counts to one row per classification with a column
#' per vintage. Kept dependency-free (no tidyr).
tidyr_pivot_wider_years <- function(counts) {
  years <- sort(unique(counts$ais_year))
  base  <- unique(counts[, c("classification", "n_charities_all_years")])
  for (yr in years) {
    col <- sprintf("programs_%s", yr)
    idx <- match(base$classification,
                 counts$classification[counts$ais_year == yr])
    base[[col]] <- counts$n_programs[counts$ais_year == yr][idx]
  }
  base[order(-base$n_charities_all_years), ]
}

# ---- Final output: charity_target_subtypes -----------------------------------

#' Build the charity_target_subtypes analytical output.
#'
#' One row per abn x subtype x provenance:
#'   - source = "register_boolean" : human_rights from the register column
#'   - source = "manual_mapping"   : curated rows in data/mappings/target_subtypes.csv
#'   - source = "rule"             : whitelisted rules only (rule_id recorded)
build_charity_target_subtypes <- function(register_path, programs_files,
                                          mapping_file, rules_file,
                                          analytical_dir) {
  register <- arrow::read_parquet(register_path)
  rules    <- readr::read_csv(rules_file, show_col_types = FALSE)
  mapping  <- readr::read_csv(mapping_file, show_col_types = FALSE,
                              col_types = readr::cols(.default = readr::col_character()))

  # --- validate inputs loudly
  bad_status <- setdiff(unique(rules$status), c("candidate", "whitelisted"))
  if (length(bad_status) > 0) {
    cli::cli_abort("Unknown rule status{?es} in {.path {rules_file}}: {.val {bad_status}}")
  }
  bad_type <- setdiff(unique(rules$rule_type),
                      c("name_keyword", "classie_classification"))
  if (length(bad_type) > 0) {
    cli::cli_abort("Unknown rule_type{?s} in {.path {rules_file}}: {.val {bad_type}}")
  }
  if (nrow(mapping) > 0) {
    bad_subtype <- setdiff(unique(mapping$subtype), TARGET_SUBTYPES)
    if (length(bad_subtype) > 0) {
      cli::cli_abort("Unknown subtype{?s} in {.path {mapping_file}}: {.val {bad_subtype}}")
    }
    bad_abn <- mapping$abn[nchar(stringr::str_remove_all(mapping$abn, "[^0-9]")) != 11]
    if (length(bad_abn) > 0) {
      cli::cli_abort("Malformed ABN{?s} in {.path {mapping_file}}: {.val {bad_abn}}")
    }
  }

  # --- 1. human_rights straight from the register boolean
  hr_col <- "promoting_or_protecting_human_rights"
  if (!hr_col %in% names(register)) {
    cli::cli_abort("Register is missing the {.field {hr_col}} column.")
  }
  hr <- register[!is.na(register[[hr_col]]) & register[[hr_col]] == "Y",
                 c("abn", "charity_legal_name")]
  hr$subtype <- "human_rights"
  hr$source  <- "register_boolean"
  hr$rule_id <- NA_character_

  # --- 2. manual mapping (curated ABNs)
  manual <- NULL
  if (nrow(mapping) > 0) {
    manual <- data.frame(
      abn     = stringr::str_remove_all(mapping$abn, "[^0-9]"),
      subtype = mapping$subtype,
      source  = "manual_mapping",
      rule_id = NA_character_,
      stringsAsFactors = FALSE
    )
    manual <- dplyr::left_join(
      manual, register[, c("abn", "charity_legal_name")], by = "abn"
    )
    unmatched <- manual$abn[is.na(manual$charity_legal_name)]
    if (length(unmatched) > 0) {
      cli::cli_alert_warning(
        "{length(unmatched)} manually mapped ABN{?s} not on the ACNC register: {.val {unmatched}}"
      )
    }
  }

  # --- 3. whitelisted rules only
  active <- rules[rules$status == "whitelisted", ]
  cli::cli_alert_info(
    "{nrow(active)} whitelisted rule{?s} of {nrow(rules)} total; candidates are NOT auto-included"
  )

  rule_rows <- NULL
  if (nrow(active) > 0) {
    programs <- read_ais_program_classifications(programs_files)
    rule_rows <- lapply(seq_len(nrow(active)), function(i) {
      r <- active[i, ]
      if (r$rule_type == "name_keyword") {
        hits <- register[stringr::str_detect(
          register$charity_legal_name,
          stringr::regex(r$pattern, ignore_case = TRUE)
        ), c("abn", "charity_legal_name")]
      } else {  # classie_classification
        abns <- unique(programs$abn[programs$classification == r$pattern])
        hits <- register[register$abn %in% abns, c("abn", "charity_legal_name")]
      }
      if (nrow(hits) == 0) {
        cli::cli_alert_warning("Whitelisted rule {r$rule_id} matched 0 charities")
        return(NULL)
      }
      hits$subtype <- r$subtype
      hits$source  <- "rule"
      hits$rule_id <- r$rule_id
      hits
    })
    rule_rows <- dplyr::bind_rows(rule_rows)
  }

  combined <- dplyr::bind_rows(hr, manual, rule_rows) |>
    dplyr::distinct(abn, subtype, source, rule_id, .keep_all = TRUE) |>
    dplyr::arrange(subtype, source, charity_legal_name)
  combined$ingestion_date <- Sys.Date()

  tallies <- combined |> dplyr::count(subtype, source)
  for (i in seq_len(nrow(tallies))) {
    cli::cli_alert_info(
      "{tallies$subtype[i]} / {tallies$source[i]}: {tallies$n[i]} charities"
    )
  }

  out <- file.path(analytical_dir, "charity_target_subtypes.parquet")
  write_outputs(combined, out)
}
