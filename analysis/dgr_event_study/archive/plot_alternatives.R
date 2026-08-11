# Three alternative "hero" charts for the switchers-are-different story.
# Reads CSVs produced by dgr_endorsement_event_study.R.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(ggplot2)
})

out_dir <- file.path(here::here(), "analysis", "dgr_event_study")

three   <- read.csv(file.path(out_dir, "three_cohort_by_year.csv"))
placebo <- read.csv(file.path(out_dir, "placebo_event_profile.csv"))
coh_cal <- read.csv(file.path(out_dir, "cohort_calendar_real.csv"))

cohort_labels <- c(switcher = "Switchers (endorsed 2020-23)",
                   always   = "Always DGR (placebo event)",
                   never    = "Never DGR (placebo event)")
cohort_cols <- c("#D55E00", "#7f7f7f", "#b0b0b0")
names(cohort_cols) <- unname(cohort_labels)

# ---- Alt 1: event-time step vs placebo lines ----------------------------------

a1_dat <- placebo |>
  mutate(cohort = factor(cohort_labels[cohort_plot], unname(cohort_labels)))

alt1 <- ggplot(a1_dat, aes(event_year, index, colour = cohort)) +
  geom_hline(yintercept = 100, linetype = "dotted", colour = "grey60") +
  geom_vline(xintercept = 0, linetype = "dashed", colour = "grey40") +
  annotate("text", x = 0.1, y = max(a1_dat$index) * 1.02,
           label = "endorsement", hjust = 0, size = 3.2, colour = "grey40") +
  geom_line(aes(linewidth = cohort == cohort_labels["switcher"])) +
  geom_point(size = 2.2) +
  scale_linewidth_manual(values = c(`TRUE` = 1.4, `FALSE` = 0.7), guide = "none") +
  scale_colour_manual(values = cohort_cols) +
  scale_x_continuous(breaks = -3:3) +
  labs(
    title = "Median real donations step up at DGR endorsement",
    subtitle = paste0(
      "Indexed to the year before endorsement (event -1 = 100). Comparison charities\n",
      "are given placebo endorsement years drawn from the same distribution."),
    x = "Years relative to (placebo) endorsement", y = "Index (event -1 = 100)",
    colour = NULL
  ) +
  theme_minimal() + theme(legend.position = "bottom") +
  guides(colour = guide_legend(nrow = 3))

ggsave(file.path(out_dir, "alt1_event_placebo.png"), alt1,
       width = 7, height = 5.5, dpi = 150)

# ---- Alt 2: small multiples by endorsement cohort ------------------------------

bench <- three |>
  filter(cohort3 %in% c("always", "never")) |>
  transmute(ais_year, med_donations_real,
            series = if_else(cohort3 == "always", "Always DGR", "Never DGR"))

a2_dat <- coh_cal |>
  mutate(facet = paste0("Endorsed FY", endorsement_fy,
                        "  (n\u2248", round(max(n)), ")"))
# n per facet: use cohort max obs
a2_dat <- coh_cal |>
  group_by(endorsement_fy) |>
  mutate(facet = sprintf("Endorsed FY%d (n=%d)", endorsement_fy, max(n))) |>
  ungroup()

alt2 <- ggplot(a2_dat, aes(ais_year, med_donations_real)) +
  geom_line(data = bench |> rename(series_val = med_donations_real),
            aes(y = series_val, group = series, colour = series),
            linewidth = 0.6) +
  geom_vline(aes(xintercept = endorsement_fy), linetype = "dashed",
             colour = "grey40") +
  geom_line(aes(colour = "Switcher cohort"), linewidth = 1.3) +
  geom_point(colour = "#D55E00", size = 1.8) +
  facet_wrap(~facet) +
  scale_colour_manual(values = c("Switcher cohort" = "#D55E00",
                                 "Always DGR" = "#7f7f7f",
                                 "Never DGR" = "#b0b0b0")) +
  scale_y_log10(labels = scales::dollar) +
  labs(
    title = "Each endorsement cohort steps up at its own endorsement year",
    subtitle = "Median real donations (FY2019 $, log scale); dashed line = cohort endorsement FY",
    x = "AIS year", y = "Median real donations (log)", colour = NULL
  ) +
  theme_minimal() + theme(legend.position = "bottom")

ggsave(file.path(out_dir, "alt2_small_multiples.png"), alt2,
       width = 9, height = 7, dpi = 150)

# ---- Alt 3: pre/post dumbbell-slope chart ---------------------------------------

# Switchers: pooled real medians pre (event < 0) vs post (event >= 1) come from
# levels_real_by_event_year.csv; comparisons: 2019 vs 2024 calendar endpoints.
event_real <- read.csv(file.path(out_dir, "levels_real_by_event_year.csv"))

sw_pre  <- event_real |> filter(event_year < 0) |>
  summarise(v = weighted.mean(med_donations_real, n)) |> pull(v)
sw_post <- event_real |> filter(event_year >= 1) |>
  summarise(v = weighted.mean(med_donations_real, n)) |> pull(v)

a3_dat <- bind_rows(
  tibble(cohort = "Switchers", period = c("Before", "After"),
         value = c(sw_pre, sw_post)),
  three |> filter(ais_year %in% c(2019, 2024)) |>
    transmute(cohort = c(always = "Always DGR", never = "Never DGR",
                         switcher = "drop")[cohort3],
              period = if_else(ais_year == 2019, "Before", "After"),
              value  = med_donations_real) |>
    filter(cohort != "drop")
) |>
  mutate(period = factor(period, c("Before", "After")),
         cohort = factor(cohort, c("Switchers", "Always DGR", "Never DGR")))

a3_cols <- c("Switchers" = "#D55E00", "Always DGR" = "#7f7f7f",
             "Never DGR" = "#b0b0b0")

alt3 <- ggplot(a3_dat, aes(period, value, group = cohort, colour = cohort)) +
  geom_line(aes(linewidth = cohort == "Switchers")) +
  geom_point(size = 3) +
  geom_text(data = a3_dat |> filter(period == "After"),
            aes(label = scales::dollar(round(value))),
            hjust = -0.25, size = 3.4, show.legend = FALSE) +
  scale_linewidth_manual(values = c(`TRUE` = 1.6, `FALSE` = 0.7), guide = "none") +
  scale_colour_manual(values = a3_cols) +
  scale_y_log10(labels = scales::dollar,
                expand = expansion(mult = c(0.05, 0.18))) +
  labs(
    title = "Median real donations, before vs after endorsement",
    subtitle = paste0(
      "Switchers: pre vs post endorsement (pooled event years). Comparisons:\n",
      "2019 vs 2024. FY2019 dollars, log scale."),
    x = NULL, y = "Median real donations (log)", colour = NULL
  ) +
  theme_minimal() + theme(legend.position = "bottom")

ggsave(file.path(out_dir, "alt3_dumbbell.png"), alt3,
       width = 6.5, height = 5.5, dpi = 150)

message("Alt charts written: alt1_event_placebo, alt2_small_multiples, alt3_dumbbell")
