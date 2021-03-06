#' ---
#' editor_options: 
#'   chunk_output_type: console
#' ---
#' 
#' # Modelling Species Occupancy 
#' 
#' ### Load necessary libraries
## ----load_libraries, , message=FALSE, warning=FALSE---------------------------
# Load libraries
library(auk)
library(lubridate)
library(sf)
library(unmarked)
library(raster)
library(ebirdst)
library(MuMIn)
library(AICcmodavg)
library(fields)
library(tidyverse)
library(doParallel)
library(snow)
library(openxlsx)
library(data.table)
library(dplyr)
library(ecodist)

# Source necessary functions
source("code/fun_screen_cor.R")
source("code/fun_model_estimate_collection.r")

#' 
#' ## Load dataframe and scale covariates
#' 
#' Here, we load the required dataframe that contains 10 random visits to a site and environmental covariates that were prepared at a spatial scale of 2.5 sq.km. We also scaled all covariates (mean around 0 and standard deviation of 1). Next, we ensured that only Traveling and Stationary checklists were considered. Even though stationary counts have no distance traveled, we defaulted all stationary accounts to an effective distance of 100m, which we consider the average maximum detection radius for most bird species in our area. Following this, we excluded predictors with a Pearson coefficient > 0.5 which resulted in the removal of grasslands as it was highly negatively correlated with forests (r = -0.77).  
#' 
#' Please note that species-specific plots of probabilities of occupancy as a function of environmental data can be accessed in Section 10 of the Supplementary Material. 
## ----load_dataframe-----------------------------------------------------------
# Load in the prepared dataframe that contains 10 random visits to each site
dat <- fread("data/04_data-covars-2.5km.csv", header = T)
setDF(dat)
head(dat)

# Some more pre-processing to get the right data structures

# Ensuring that only Traveling and Stationary checklists were considered
names(dat)
dat <- dat %>% filter(protocol_type %in% c("Traveling", "Stationary"))

# We take all stationary counts and give them a distance of 100 m (so 0.1 km),
# as that's approximately the max normal hearing distance for people doing point counts.
dat <- dat %>%
  mutate(effort_distance_km = replace(
    effort_distance_km,
    which(effort_distance_km == 0 &
      protocol_type == "Stationary"),
    0.1
  ))

# Converting time observations started to numeric and adding it as a new column
# This new column will be minute_observations_started
dat <- dat %>%
  mutate(min_obs_started = strtoi(as.difftime(time_observations_started,
    format = "%H:%M:%S", units = "mins"
  )))

# Adding the julian date to the dataframe
dat <- dat %>% mutate(julian_date = lubridate::yday(dat$observation_date))

# Removing other unnecessary columns from the dataframe and creating a clean one without the rest
names(dat)
dat <- dat[, -c(1, 4, 5, 16, 18, 21, 23, 24, 25, 26, 28:37, 39:45, 47)]

# Rename column names:
names(dat) <- c(
  "duration_minutes", "effort_distance_km", "locality",
  "locality_type", "locality_id", "observer_id",
  "observation_date", "scientific_name", "observation_count",
  "protocol_type", "number_observers", "pres_abs", "tot_effort",
  "longitude", "latitude", "expertise", "bio_1.y", "bio_12.y",
  "lc_02.y", "lc_06.y", "lc_01.y", "lc_07.y", "lc_04.y",
  "lc_05.y", "min_obs_started", "julian_date"
)

dat.1 <- dat %>%
  mutate(
    year = year(observation_date),
    pres_abs = as.integer(pres_abs)
  ) # occupancy modeling requires an integer response

# Dividing Annual Mean Temperature by 10 to arrive at accurate values of temperature
dat.1$bio_1.y <- dat.1$bio_1.y / 10

# Scaling detection and occupancy covariates
dat.scaled <- dat.1
dat.scaled[, c(1, 2, 11, 16:25)] <- scale(dat.scaled[, c(1, 2, 11, 16:25)]) # Scaling and standardizing detection and site-level covariates
fwrite(dat.scaled, file = "data/05_scaled-covars-2.5km.csv")

# Reload the scaled covariate data
dat.scaled <- fread("data/05_scaled-covars-2.5km.csv", header = T)
setDF(dat.scaled)
head(dat.scaled)

# Ensure observation_date column is in the right format
dat.scaled$observation_date <- format(
  as.Date(
    dat.scaled$observation_date,
    "%m/%d/%Y"
  ),
  "%Y-%m-%d"
)

# Testing for correlations before running further analyses
# Most are uncorrelated since we decided to keep only 2 climatic and 6 land cover predictors
source("code/screen_cor.R")
names(dat.scaled)
screen.cor(dat.scaled[, c(1, 2, 11, 16:25)], threshold = 0.5)

#' 
#' ## Running a null model
#' 
## ----null_model---------------------------------------------------------------
# All null models are stored in lists below
all_null <- list()

# Add a progress bar for the loop
pb <- txtProgressBar(
  min = 0,
  max = length(unique(dat.scaled$scientific_name)),
  style = 3
) # text based bar

for (i in 1:length(unique(dat.scaled$scientific_name))) {
  data <- dat.scaled %>% 
  filter(dat.scaled$scientific_name == unique(dat.scaled$scientific_name)[i])

  # Preparing data for the unmarked model
  occ <- filter_repeat_visits(data,
    min_obs = 1, max_obs = 10,
    annual_closure = FALSE,
    n_days = 2600, # 7 years is considered a period of closure
    date_var = "observation_date",
    site_vars = c("locality_id")
  )

  obs_covs <- c(
    "min_obs_started",
    "duration_minutes",
    "effort_distance_km",
    "number_observers",
    "protocol_type",
    "expertise",
    "julian_date"
  )

  # format for unmarked
  occ_wide <- format_unmarked_occu(occ,
    site_id = "site",
    response = "pres_abs",
    site_covs = c("locality_id", "lc_01.y", "lc_02.y", "lc_04.y", 
    "lc_05.y", "lc_06.y", "lc_07.y", "bio_1.y", "bio_12.y"),
    obs_covs = obs_covs
  )

  # Convert this dataframe of observations into an unmarked object to start fitting occupancy models
  occ_um <- formatWide(occ_wide, type = "unmarkedFrameOccu")

  # Set up the model
  all_null[[i]] <- occu(~1 ~ 1, data = occ_um)
  names(all_null)[i] <- unique(dat.scaled$scientific_name)[i]
  setTxtProgressBar(pb, i)
}
close(pb)

# Store all the  model outputs for each species
capture.output(all_null, file = "data\results\null_models.csv")

#' 
#' 
#' ## Identifying covariates necessary to model the detection process
#' 
#' Here, we use the `unmarked` package in R [@fiske2011] to identify detection level covariates that are important for each species. We use AIC criteria to select top models [@burnham2011].
## ----prob_detection-----------------------------------------------------------

# All models are stored in lists below
det_dred <- list()

# Subsetting those models whose deltaAIC<2 (Burnham et al., 2011)
top_det <- list()

# Getting model averaged coefficients and relative importance scores
det_avg <- list()
det_imp <- list()

# Getting model estimates
det_modelEst <- list()

# Add a progress bar for the loop
pb <- txtProgressBar(min = 0, 
  max = length(unique(dat.scaled$scientific_name)), style = 3) # text based bar

for (i in 1:length(unique(dat.scaled$scientific_name))) {
  data <- dat.scaled %>% 
    filter(dat.scaled$scientific_name == unique(dat.scaled$scientific_name)[i])

  # Preparing data for the unmarked model
  occ <- filter_repeat_visits(data,
    min_obs = 1, max_obs = 10,
    annual_closure = FALSE,
    n_days = 2600, # 6 years is considered a period of closure
    date_var = "observation_date",
    site_vars = c("locality_id")
  )

  obs_covs <- c(
    "min_obs_started",
    "duration_minutes",
    "effort_distance_km",
    "number_observers",
    "protocol_type",
    "expertise",
    "julian_date"
  )

  # format for unmarked
  occ_wide <- format_unmarked_occu(occ,
    site_id = "site",
    response = "pres_abs",
    site_covs = c("locality_id", "lc_01.y", "lc_02.y", "lc_04.y", 
      "lc_05.y", "lc_06.y", "lc_07.y", "bio_1.y", "bio_12.y"), 
      obs_covs = obs_covs
  )

  # Convert this dataframe of observations into an unmarked object to start fitting occupancy models
  occ_um <- formatWide(occ_wide, type = "unmarkedFrameOccu")

  # Fit a global model with all detection level covariates
  global_mod <- occu(~ min_obs_started +
    julian_date +
    duration_minutes +
    effort_distance_km +
    number_observers +
    protocol_type +
    expertise ~ 1, data = occ_um)

  # Set up the cluster
  clusterType <- if (length(find.package("snow", quiet = TRUE))) "SOCK" else "PSOCK"
  clust <- try(makeCluster(getOption("cl.cores", 6), type = clusterType))

  clusterEvalQ(clust, library(unmarked))
  clusterExport(clust, "occ_um")

  det_dred[[i]] <- pdredge(global_mod, clust)
  names(det_dred)[i] <- unique(dat.scaled$scientific_name)[i]

  # Get the top models, which we'll define as those with deltaAICc < 2
  top_det[[i]] <- get.models(det_dred[[i]], subset = delta < 2, cluster = clust)
  names(top_det)[i] <- unique(dat.scaled$scientific_name)[i]

  # Obtaining model averaged coefficients
  if (length(top_det[[i]]) > 1) {
    a <- model.avg(top_det[[i]], fit = TRUE)
    det_avg[[i]] <- as.data.frame(a$coefficients)
    names(det_avg)[i] <- unique(dat.scaled$scientific_name)[i]


    det_modelEst[[i]] <- data.frame(
      Coefficient = coefTable(a, full = T)[, 1],
      SE = coefTable(a, full = T)[, 2],
      lowerCI = confint(a)[, 1],
      upperCI = confint(a)[, 2],
      z_value = (summary(a)$coefmat.full)[, 3],
      Pr_z = (summary(a)$coefmat.full)[, 4]
    )

    names(det_modelEst)[i] <- unique(dat.scaled$scientific_name)[i]

    det_imp[[i]] <- as.data.frame(MuMIn::importance(a))
    names(det_imp)[i] <- unique(dat.scaled$scientific_name)[i]
  } else {
    det_avg[[i]] <- as.data.frame(unmarked::coef(top_det[[i]][[1]]))
    names(det_avg)[i] <- unique(dat.scaled$scientific_name)[i]

    lowDet <- data.frame(lowerCI = confint(top_det[[i]][[1]], type = "det")[, 1])
    upDet <- data.frame(upperCI = confint(top_det[[i]][[1]], type = "det")[, 2])
    zDet <- data.frame(summary(top_det[[i]][[1]])$det[, 3])
    Pr_zDet <- data.frame(summary(top_det[[i]][[1]])$det[, 4])

    Coefficient <- coefTable(top_det[[i]][[1]])[, 1]
    SE <- coefTable(top_det[[i]][[1]])[, 2]

    det_modelEst[[i]] <- data.frame(
      Coefficient = Coefficient[2:9],
      SE = SE[2:9],
      lowerCI = lowDet,
      upperCI = upDet,
      z_value = zDet,
      Pr_z = Pr_zDet
    )

    names(det_modelEst)[i] <- unique(dat.scaled$scientific_name)[i]
  }
  setTxtProgressBar(pb, i)
  stopCluster(clust)
}
close(pb)

## Storing output from the above models in excel sheets

# 1. Store all the model outputs for each species (variable: det_dred() - see above)
write.xlsx(det_dred, file = "data\results\det-dred.xlsx")

# 2. Store all the model averaged outputs for each species and the relative importance score
write.xlsx(det_avg, file = "data\results\det-avg.xlsx", rowNames = T, colNames = T)
write.xlsx(det_imp, file = "data\results\det-imp.xlsx", rowNames = T, colNames = T)

write.xlsx(det_modelEst, file = "data\results\det-modelEst.xlsx", rowNames = T, colNames = T)

#' 
#' ## Land Cover and Climate
#' 
#' Occupancy models estimate the probability of occurrence of a given species while controlling for the probability of detection and allow us to model the factors affecting occurrence and detection independently [@johnston2018; @mackenzie2002]. The flexible eBird observation process contributes to the largest source of variation in the likelihood of detecting a particular species [@johnston2019a]; hence, we included seven covariates that influence the probability of detection for each checklist: ordinal day of year, duration of observation, distance travelled, protocol type, time observations started, number of observers and the checklist calibration index (CCI). 
#' 
#' Using a multi-model information-theoretic approach, we tested how strongly our occurrence data fit our candidate set of environmental covariates [@burnham2002a]. We fitted single-species occupancy models for each species, to simultaneously estimate a probability of detection (p) and a probability of occupancy ($\psi$) [@fiske2011; @mackenzie2002]. For each species, we fit 256 models, each with a unique combination of the eight (climate and land cover) occupancy covariates and all seven detection covariates (Appendix S5). 
#' 
#' Across the 256 models tested for each species, the model with highest support was determined using AICc scores. However, across the majority of the species, no single model had overwhelming support. Hence, for each species, we examined those models which had $\Delta$AICc < 2, as these top models were considered to explain a large proportion of the association between the species-specific probability of occupancy and environmental drivers [@burnham2011; @elsen2017]. Using these restricted model sets for each species; we created a model-averaged coefficient estimate for each predictor and assessed its direction and significance [@MuMIn]. We considered a predictor to be significantly associated with occupancy if the range of the 95% confidence interval around the model-averaged coefficient did not contain zero. Next, we obtained a measure of relative importance of climatic and landscape predictors by calculating cumulative variable importance scores. These scores were calculated by obtaining the sum of model weights (AIC weights) across all models (including the top models) for each predictor across all species.  
## ----lc_clim------------------------------------------------------------------
# All models are stored in lists below
lc_clim <- list()

# Subsetting those models whose deltaAIC<2 (Burnham et al., 2011)
top_lc_clim <- list()

# Getting model averaged coefficients and relative importance scores
lc_clim_avg <- list()
lc_clim_imp <- list()

# Storing Model estimates
lc_clim_modelEst <- list()

# Add a progress bar for the loop
pb <- txtProgressBar(min = 0, max = length(unique(dat.scaled$scientific_name)), style = 3) # text based bar

for (i in 1:length(unique(dat.scaled$scientific_name))) {
  data <- dat.scaled %>% filter(dat.scaled$scientific_name == unique(dat.scaled$scientific_name)[1])

  # Preparing data for the unmarked model
  occ <- filter_repeat_visits(data,
    min_obs = 1, max_obs = 10,
    annual_closure = FALSE,
    n_days = 2600, # 6 years is considered a period of closure
    date_var = "observation_date",
    site_vars = c("locality_id")
  )

  obs_covs <- c(
    "min_obs_started",
    "duration_minutes",
    "effort_distance_km",
    "number_observers",
    "protocol_type",
    "expertise",
    "julian_date"
  )

  # format for unmarked
  occ_wide <- format_unmarked_occu(occ,
    site_id = "site",
    response = "pres_abs",
    site_covs = c("locality_id", "lc_01.y", "lc_02.y", "lc_04.y", "lc_05.y", 
      "lc_06.y", "lc_07.y", "bio_1.y", "bio_12.y"),
    obs_covs = obs_covs
  )

  # Convert this dataframe of observations into an unmarked object to start fitting occupancy models
  occ_um <- formatWide(occ_wide, type = "unmarkedFrameOccu")

  model_lc_clim <- occu(~ min_obs_started +
    julian_date +
    duration_minutes +
    effort_distance_km +
    number_observers +
    protocol_type +
    expertise ~ lc_01.y + lc_02.y + lc_04.y +
    lc_05.y + lc_06.y + lc_07.y + bio_1.y + bio_12.y, data = occ_um)

  # Set up the cluster
  clusterType <- if (length(find.package("snow", quiet = TRUE))) "SOCK" else "PSOCK"
  clust <- try(makeCluster(getOption("cl.cores", 6), type = clusterType))

  clusterEvalQ(clust, library(unmarked))
  clusterExport(clust, "occ_um")

  # Detection terms are fixed
  det_terms <- c(
    "p(duration_minutes)", "p(effort_distance_km)", "p(expertise)", 
    "p(julian_date)", "p(min_obs_started)",
    "p(number_observers)", "p(protocol_type)"
  )

  lc_clim[[i]] <- pdredge(model_lc_clim, clust, fixed = det_terms)
  names(lc_clim)[i] <- unique(dat.scaled$scientific_name)[i]

  # Identiying top subset of models based on deltaAIC scores being less than 2 (Burnham et al., 2011)
  top_lc_clim[[i]] <- get.models(lc_clim[[i]], subset = delta < 2, cluster = clust)

  names(top_lc_clim)[i] <- unique(dat.scaled$scientific_name)[i]

  # Obtaining model averaged coefficients for both candidate model subsets
  if (length(top_lc_clim[[i]]) > 1) {
    a <- model.avg(top_lc_clim[[i]], fit = TRUE)
    lc_clim_avg[[i]] <- as.data.frame(a$coefficients)
    names(lc_clim_avg)[i] <- unique(dat.scaled$scientific_name)[i]

    lc_clim_modelEst[[i]] <- data.frame(
      Coefficient = coefTable(a, full = T)[, 1],
      SE = coefTable(a, full = T)[, 2],
      lowerCI = confint(a)[, 1],
      upperCI = confint(a)[, 2],
      z_value = (summary(a)$coefmat.full)[, 3],
      Pr_z = (summary(a)$coefmat.full)[, 4]
    )

    names(lc_clim_modelEst)[i] <- unique(dat.scaled$scientific_name)[i]

    lc_clim_imp[[i]] <- as.data.frame(MuMIn::importance(a))
    names(lc_clim_imp)[i] <- unique(dat.scaled$scientific_name)[i]
  } else {
    lc_clim_avg[[i]] <- as.data.frame(unmarked::coef(top_lc_clim[[i]][[1]]))
    names(lc_clim_avg)[i] <- unique(dat.scaled$scientific_name)[i]

    lowSt <- data.frame(lowerCI = confint(top_lc_clim[[i]][[1]], type = "state")[, 1])
    lowDet <- data.frame(lowerCI = confint(top_lc_clim[[i]][[1]], type = "det")[, 1])
    upSt <- data.frame(upperCI = confint(top_lc_clim[[i]][[1]], type = "state")[, 2])
    upDet <- data.frame(upperCI = confint(top_lc_clim[[i]][[1]], type = "det")[, 2])
    zSt <- data.frame(z_value = summary(top_lc_clim[[i]][[1]])$state[, 3])
    zDet <- data.frame(z_value = summary(top_lc_clim[[i]][[1]])$det[, 3])
    Pr_zSt <- data.frame(Pr_z = summary(top_lc_clim[[i]][[1]])$state[, 4])
    Pr_zDet <- data.frame(Pr_z = summary(top_lc_clim[[i]][[1]])$det[, 4])

    lc_clim_modelEst[[i]] <- data.frame(
      Coefficient = coefTable(top_lc_clim[[i]][[1]])[, 1],
      SE = coefTable(top_lc_clim[[i]][[1]])[, 2],
      lowerCI = rbind(lowSt, lowDet),
      upperCI = rbind(upSt, upDet),
      z_value = rbind(zSt, zDet),
      Pr_z = rbind(Pr_zSt, Pr_zDet)
    )

    names(lc_clim_modelEst)[i] <- unique(dat.scaled$scientific_name)[i]
  }
  setTxtProgressBar(pb, i)
  stopCluster(clust)
}
close(pb)

# 1. Store all the model outputs for each species (for both landcover and climate)
write.xlsx(lc_clim, file = "data\results\lc-clim.xlsx")

# 2. Store all the model averaged outputs for each species and relative importance scores
write.xlsx(lc_clim_avg, file = "data\results\lc-clim-avg.xlsx", rowNames = T, colNames = T)
write.xlsx(lc_clim_imp, file = "data\results\lc-clim-imp.xlsx", rowNames = T, colNames = T)

# 3. Store all model estimates
write.xlsx(lc_clim_modelEst, file = "data\results\lc-clim-modelEst.xlsx", rowNames = T, colNames = T)

#' 
#' ## Goodness-of-fit tests
#' 
#' Adequate model fit was assessed using a chi-square goodness-of-fit test using 5000 parametric bootstrap simulations on a global model that included all occupancy and detection covariates (MacKenzie & Bailey, 2004). 
## -----------------------------------------------------------------------------
goodness_of_fit <- data.frame()

# Add a progress bar for the loop
pb <- txtProgressBar(min = 0, max = length(unique(dat.scaled$scientific_name)), style = 3) # text based bar

for (i in 1:length(unique(dat.scaled$scientific_name))) {
  data <- dat.scaled %>% filter(dat.scaled$scientific_name == unique(dat.scaled$scientific_name)[i])

  # Preparing data for the unmarked model
  occ <- filter_repeat_visits(data,
    min_obs = 1, max_obs = 10,
    annual_closure = FALSE,
    n_days = 2600, # 6 years is considered a period of closure
    date_var = "observation_date",
    site_vars = c("locality_id")
  )

  obs_covs <- c(
    "min_obs_started",
    "duration_minutes",
    "effort_distance_km",
    "number_observers",
    "protocol_type",
    "expertise",
    "julian_date"
  )

  # format for unmarked
  occ_wide <- format_unmarked_occu(occ,
    site_id = "site",
    response = "pres_abs",
    site_covs = c("locality_id", "lc_01.y", "lc_02.y", "lc_04.y", "lc_05.y", "lc_06.y", "lc_07.y", "bio_1.y", "bio_12.y"),
    obs_covs = obs_covs
  )

  # Convert this dataframe of observations into an unmarked object to start fitting occupancy models
  occ_um <- formatWide(occ_wide, type = "unmarkedFrameOccu")

  model_lc_clim <- occu(~ min_obs_started +
    julian_date +
    duration_minutes +
    effort_distance_km +
    number_observers +
    protocol_type +
    expertise ~ lc_01.y + lc_02.y + lc_04.y +
    lc_05.y + lc_06.y + lc_07.y + bio_1.y + bio_12.y, data = occ_um)

  occ_gof <- mb.gof.test(model_lc_clim, nsim = 5000, plot.hist = FALSE)

  p.value <- occ_gof$p.value
  c.hat <- occ_gof$c.hat.est
  scientific_name <- unique(data$scientific_name)

  a <- data.frame(scientific_name, p.value, c.hat)

  goodness_of_fit <- rbind(a, goodness_of_fit)

  setTxtProgressBar(pb, i)
}
close(pb)

write.csv(goodness_of_fit, "data\results\05_goodness-of-fit-2.5km.csv")

