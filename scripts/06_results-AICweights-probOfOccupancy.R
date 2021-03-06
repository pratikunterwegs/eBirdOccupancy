#' ---
#' editor_options: 
#'   chunk_output_type: console
#' ---
#' 
#' # Visualizing Occupancy Predictor Effects
#' 
#' In this section, we will visualize the cumulative AIC weights and the magnitude and direction of species-specific probability of occupancy. 
#' 
#' To get cumulative AIC weights, we first obtained a measure of relative importance of climatic and landscape predictors by calculating cumulative variable importance scores. These scores were calculated by obtaining the sum of model weights (AIC weights) across all models (including the top models) for each predictor across all species. We then calculated the mean cumulative variable importance score and a standard deviation for each predictor [@burnham2002a]. 
#' 
#' ## Prepare libraries
#' 
## ----load_libs_results01------------------------------------------------------
# to load data
library(readxl)

# to handle data
library(dplyr)
library(readr)
library(forcats)
library(tidyr)
library(purrr)
library(stringr)
library(data.table)

# to wrangle models
source("code/fun_model_estimate_collection.r")
source("code/fun_make_resp_data.r")

# nice tables
library(knitr)
library(kableExtra)

# plotting
library(ggplot2)
library(patchwork)
source("code/fun_plot_interaction.r")

#' 
#' ## Load species list
#' 
## -----------------------------------------------------------------------------
# list of species
species <- read_csv("data/species_list.csv")
list_of_species <- as.character(species$scientific_name)

#' 
#' ## Show AIC weight importance
#' 
#' ### Read in AIC weight data
#' 
## -----------------------------------------------------------------------------
# which files to read
file_names <- c("data/results/lc-clim-imp.xlsx")

# read in sheets by species
model_imp <- map(file_names, function(f) {
  md_list <- map(list_of_species, function(sn) {

    # some sheets are not found

    tryCatch(
      {
        readxl::read_excel(f, sheet = sn) %>%
          `colnames<-`(c("predictor", "AIC_weight")) %>%
          filter(str_detect(predictor, "psi")) %>%
          mutate(
            predictor = stringr::str_extract(predictor,
              pattern = stringr::regex("\\((.*?)\\)")
            ),
            predictor = stringr::str_replace_all(predictor, "[//(//)]", ""),
            predictor = stringr::str_remove(predictor, "\\.y")
          )
      },
      error = function(e) {
        message(as.character(e))
      }
    )
  })
  names(md_list) <- list_of_species

  return(md_list)
})

#' 
#' ### Prepare cumulative AIC weight data
#' 
## -----------------------------------------------------------------------------
# assign scale - minimum spatial scale at which the analysis was carried out to account for observer effort
names(model_imp) <- c("2.5km")
model_imp <- imap(model_imp, function(.x, .y) {
  .x <- bind_rows(.x)
  .x$scale <- .y
  return(.x)
})

# bind rows
model_imp <- map(model_imp, bind_rows) %>%
  bind_rows()

# convert to numeric
model_imp$AIC_weight <- as.numeric(model_imp$AIC_weight)
model_imp$scale <- as.factor(model_imp$scale)
levels(model_imp$scale) <- c("2.5km")

# Let's get a summary of cumulative variable importance
model_imp <- group_by(model_imp, predictor) %>%
  summarise(
    mean_AIC = mean(AIC_weight),
    sd_AIC = sd(AIC_weight),
    min_AIC = min(AIC_weight),
    max_AIC = max(AIC_weight),
    med_AIC = median(AIC_weight)
  )

# write to file
write_csv(model_imp,
  file = "data/results/cumulative_AIC_weights.csv"
)

#' 
#' Read data back in.
## -----------------------------------------------------------------------------
# read data and make factor
model_imp <- read_csv("data/results/cumulative_AIC_weights.csv")
model_imp$predictor <- as_factor(model_imp$predictor)

#' 
## -----------------------------------------------------------------------------
# make nice names
predictor_name <- tibble(
  predictor = levels(model_imp$predictor),
  pred_name = c(
    "Annual Mean Temperature (°C)",
    "Annual Precipitation (mm)",
    "% Agriculture", "% Forests",
    "% Plantations", "% Settlements",
    "% Tea", "% Water Bodies"
  )
)

# rename predictor
model_imp <- left_join(model_imp, predictor_name)

#' 
#' Prepare figure for cumulative AIC weight. Figure code is hidden in versions rendered as HTML and PDF.
## -----------------------------------------------------------------------------
fig_aic <-
  ggplot(model_imp) +
  geom_pointrange(aes(
    x = reorder(predictor, mean_AIC),
    y = mean_AIC,
    ymin = mean_AIC - sd_AIC,
    ymax = mean_AIC + sd_AIC
  )) +
  geom_text(aes(
    x = predictor,
    y = 0.2,
    label = pred_name
  ),
  angle = 0,
  hjust = "inward",
  vjust = 2
  ) +
  # scale_y_continuous(breaks = seq(45, 75, 10))+
  scale_x_discrete(labels = NULL) +
  # scale_color_brewer(palette = "RdBu", values = c(0.5, 1))+
  coord_flip(
    # ylim = c(45, 75)
  ) +
  theme_test() +
  theme(legend.position = "none") +
  labs(
    x = "Predictor",
    y = "Cumulative AIC weight"
  )

ggsave(fig_aic,
  filename = "figs/fig_aic_weight.png",
  device = png(),
  dpi = 300,
  width = 79, height = 120, units = "mm"
)

#' 
#' ## Prepare model coefficient data
#' 
#' For each species, we examined those models which had ΔAICc < 2, as these top models were considered to explain a large proportion of the association between the species-specific probability of occupancy and environmental drivers [@burnham2011; @elsen2017]. Using these restricted model sets for each species; we created a model-averaged coefficient estimate for each predictor and assessed its direction and significance [@MuMIn]. We considered a predictor to be significantly associated with occupancy if the range of the 95% confidence interval around the model-averaged coefficient did not contain zero.  
## ----read_model_estimates-----------------------------------------------------
file_read <- c("data/results/lc-clim-modelEst.xlsx")

# read data as list column
model_est <- map(file_read, function(fr) {
  md_list <- map(list_of_species, function(sn) {
    readxl::read_excel(fr, sheet = sn)
  })
  names(md_list) <- list_of_species
  return(md_list)
})

# prepare model data
scales <- c("2.5km")
model_data <- tibble(
  scale = scales,
  scientific_name = list_of_species
) %>%
  arrange(desc(scale))

# rename model data components and separate predictors
names <- c(
  "predictor", "coefficient", "se", "ci_lower",
  "ci_higher", "z_value", "p_value"
)

# get data for plotting:
model_est <- map(model_est, function(l) {
  map(l, function(df) {
    colnames(df) <- names
    df <- separate_interaction_terms(df)
    df <- make_response_data(df)
    return(df)
  })
})

# add names and scales
model_est <- map(model_est, function(l) {
  imap(l, function(.x, .y) {
    mutate(.x, scientific_name = .y)
  })
})

# add names to model estimates
names(model_est) <- scales
model_est <- imap(model_est, function(.x, .y) {
  bind_rows(.x) %>%
    mutate(scale = .y)
})

# remove modulators
model_est <- bind_rows(model_est) %>%
  select(-matches("modulator"))

# join data to species name
model_data <- model_data %>%
  left_join(model_est)

# Keep only those predictors whose p-values are significant:
model_data <- model_data %>%
  filter(p_value < 0.05)

#' 
#' Export predictor effects.
## -----------------------------------------------------------------------------
# get predictor effect data
data_predictor_effect <- distinct(
  model_data,
  scientific_name,
  se,
  predictor, coefficient
)

# write to file
write_csv(data_predictor_effect,
  path = "data/results/data_predictor_effect.csv"
)

#' 
#' Export model data.
## -----------------------------------------------------------------------------
model_data_to_file <- model_data %>%
  select(
    predictor, data,
    scientific_name, scale
  ) %>%
  unnest(cols = "data")

# remove .y
model_data_to_file <- model_data_to_file %>%
  mutate(predictor = str_remove(predictor, "\\.y"))

write_csv(
  model_data_to_file,
  "data/results/data_occupancy_predictors.csv"
)

#' 
#' Read in data after clearing R session.
## -----------------------------------------------------------------------------
# read from file
model_data <- read_csv("data/results/data_predictor_effect.csv")

#' 
#' Fix predictor name.
## -----------------------------------------------------------------------------
# remove .y from predictors
model_data <- model_data %>%
  mutate_at(.vars = c("predictor"), .funs = function(x) {
    stringr::str_remove(x, ".y")
  })

#' 
#' ## Get predictor effects
#' 
## -----------------------------------------------------------------------------
# is the coeff positive? how many positive per scale per predictor per axis of split?
data_predictor <- mutate(model_data,
  direction = coefficient > 0
) %>%
  count(
    predictor,
    direction
  ) %>%
  mutate(mag = n * (if_else(direction, 1, -1)))

# wrangle data to get nice bars
data_predictor <- data_predictor %>%
  select(-n) %>%
  drop_na(direction) %>%
  mutate(direction = ifelse(direction, "positive", "negative")) %>%
  pivot_wider(values_from = "mag", names_from = "direction") %>%
  mutate_at(
    vars(positive, negative),
    ~ if_else(is.na(.), 0, .)
  )

data_predictor_long <- data_predictor %>%
  pivot_longer(
    cols = c("negative", "positive"),
    names_to = "effect",
    values_to = "magnitude"
  )

# write
write_csv(data_predictor_long,
  path = "data/results/data_predictor_direction_nSpecies.csv"
)

#' 
#' Prepare data to determine the direction (positive or negative) of the effect of each predictor. How many species are affected in either direction?
## -----------------------------------------------------------------------------
# join with predictor names and relative AIC
data_predictor_long <- left_join(data_predictor_long, model_imp)

#' 
#' Prepare figure of the number of species affected in each direction. Figure code is hidden in versions rendered as HTML and PDF.
## ----echo=FALSE---------------------------------------------------------------
fig_predictor <-
  ggplot(model_imp) +
  geom_hline(
    yintercept = 0,
    lwd = 0.2,
    col = "grey"
  ) +
  geom_col(
    data = data_predictor_long,
    aes(
      x = reorder(predictor, mean_AIC),
      y = magnitude,
      fill = effect
    ),
    # position = position_dodge(width = 1),
    width = 0.3
  ) +
  geom_text(aes(
    x = predictor,
    y = 0,
    label = pred_name
  ),
  angle = 0,
  vjust = 2,
  size = 4
  ) +
  scale_fill_brewer(palette = "Set1") +
  scale_x_discrete(labels = NULL) +
  coord_flip() +
  theme_test() +
  theme(legend.position = "none") +
  labs(x = "Predictor", y = "# Species")

ggsave(fig_predictor,
  filename = "figs/fig_predictor_effect.png",
  dpi = 300,
  width = 79, height = 120, units = "mm"
)

#' 
#' ## Main Text Figure 4
#' 
#' Figure code is hidden in versions rendered as HTML and PDF.
## ----echo=FALSE---------------------------------------------------------------
library(patchwork)

# wrap
fig_predictor_effect <-
  wrap_plots(fig_aic, fig_predictor) +
  plot_annotation(
    tag_levels = "a",
    tag_prefix = "(",
    tag_suffix = ")"
  )

# save
ggsave(fig_predictor_effect,
  filename = "figs/fig_04_aic_weight_effect.png",
  dpi = 300,
  width = 168, height = 130, units = "mm"
)

#' 
#' ![(a) Cumulative AIC weights suggest that climatic predictors have higher relative importance when compared to landscape predictors. (b) The direction of association between species-specific probability of occupancy and climatic and landscape is shown here. While climatic predictors were both positively and negatively associated with the probability of occupancy for a number of species, human-associated land cover types were largely negatively associated with species-specific probability of occupancy.](figs/fig_04_aic_weight_effect.png)
