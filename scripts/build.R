#' Run the full pipeline.
#'
#'   source("scripts/build.R")
#'
#' targets only re-runs steps whose inputs have changed. To force a re-run
#' of a single step:  targets::tar_invalidate("acnc_register"); targets::tar_make()
#' To force a re-download of source files, run scripts/refresh_sources.R first.

library(targets)

tar_make()

# Show what was built
tar_visnetwork()  # opens an HTML view of pipeline state (skip in headless runs)
