#' ---
#' editor_options: 
#'   chunk_output_type: console
#' ---
#' 
#' # Adding Covariates to Checklist Data
#' 
#' In this section, we prepare a final list of covariates, after taking into account spatial sampling bias (examined in the previous section), temporal bias and observer expertise scores. 
#' 
#' ## Prepare libraries and data
#' 
## ----load_libs_data, , message=FALSE, warning=FALSE---------------------------

# load libs
library(dplyr)
library(readr)
library(stringr)
library(purrr)
library(raster)
library(glue)
library(velox)
library(tidyr)
library(sf)

# load saved data object
load("data/01_ebird_data_prelim_processing.rdata")

#' 
#' ## Spatial subsampling
#' 
#' Sampling bias can be introduced into citizen science due to the often ad-hoc nature of data collection [@sullivan2014]. For eBird, this translates into checklists reported when convenient, rather than at regular or random points in time and space, leading to non-independence in the data if observations are spatio-temporally clustered [@johnston2019a]. Spatio-temporal autocorrelation in the data can be reduced by sub-sampling at an appropriate spatial resolution, and by avoiding temporal clustering. We estimated two simple measures of spatial clustering: the distance from each site to the nearest road (road data from OpenStreetMap; [@OpenStreetMap]), and the nearest-neighbor distance for each site. Sites were strongly tied to roads (mean distance to road ± SD = 390.77 ± 859.15 m; range = 0.28 m – 7.64 km) and were on average only 297 m away from another site (SD = 553 m; range = 0.14 m – 12.85 km) (Figure 3). This analysis was done in the previous section.  
#' 
#' Here, to further reduce spatial autocorrelation, we divided the study area into a grid of 1km wide square cells and picked checklists from one site at random within each grid cell. 
#' 
#' Prior to running this analysis, we checked how many checklists/data would be retained given a particular value of distance to account for spatial independence. This analysis can be accessed in Section 8 of the Supplementary Material. We show that over 80% of checklists are retained with a distance cutoff of 1km. In addition, a number of thinning approaches were tested to determine which method retained the highest proportion of points, while accounting for sampling effort (time and distance). This analysis can be accessed in Section 9 of the Supplementary Material. 
#' 
## ----spatial_thinning---------------------------------------------------------
# grid based spatial thinning
gridsize <- 1000 # grid size in metres
effort_distance_max <- 1000 # removing checklists with this distance

# make grids across the study site
hills <- st_read("data/spatial/hillsShapefile/Nil_Ana_Pal.shp") %>%
  st_transform(32643)
grid <- st_make_grid(hills, cellsize = gridsize)

# split data by species
data_spatial_thin <- split(x = dataGrouped, f = dataGrouped$scientific_name)

# spatial thinning on each species retains
# site with maximum visits per grid cell
data_spatial_thin <- map(data_spatial_thin, function(df) {

  # count visits per locality
  df <- group_by(df, locality) %>%
    mutate(tot_effort = length(sampling_event_identifier)) %>%
    ungroup()

  # remove sites with distances above spatial independence
  df <- df %>%
    filter(effort_distance_km <= effort_distance_max) %>%
    st_as_sf(coords = c("longitude", "latitude")) %>%
    `st_crs<-`(4326) %>%
    st_transform(32643) %>%
    mutate(coordId = 1:nrow(.)) %>%
    bind_cols(as_tibble(st_coordinates(.)))

  # whcih cell has which coords
  grid_contents <- st_contains(grid, df) %>%
    as_tibble() %>%
    rename(cell = row.id, coordId = col.id)

  # what's the max point in each grid
  points_max <- left_join(df %>% st_drop_geometry(),
    grid_contents,
    by = "coordId"
  ) %>%
    group_by(cell) %>%
    filter(tot_effort == max(tot_effort))

  return(points_max)
})

# remove old data
rm(dataGrouped)

#' 
#' ## Temporal subsampling
#' 
#' Additionally, from each selected site, we randomly selected a maximum of 10 checklists, which reduced temporal autocorrelation.
## ----subsample_data-----------------------------------------------------------
# subsample data for random 10 observations
dataSubsample <- map(data_spatial_thin, function(df) {
  df <- ungroup(df)
  df_to_locality <- split(x = df, f = df$locality)
  df_samples <- map_if(
    .x = df_to_locality,
    .p = function(x) {
      nrow(x) > 10
    },
    .f = function(x) sample_n(x, 10, replace = FALSE)
  )

  return(bind_rows(df_samples))
})

# bind all rows for data frame
dataSubsample <- bind_rows(dataSubsample)

# remove previous data
rm(data_spatial_thin)

#' 
#' ## Add checklist calibration index
#' 
#' Load the CCI computed in the previous section. The CCI was the lone observer’s expertise score for single-observer checklists, and the highest expertise score among observers for group checklists. 
## ----add_expertise------------------------------------------------------------
# read in obs score and extract numbers
expertiseScore <- read_csv("data/03_data-obsExpertise-score.csv") %>%
  mutate(numObserver = str_extract(observer, "\\d+")) %>%
  dplyr::select(-observer)

# group seis consist of multiple observers
# in this case, seis need to have the highest expertise observer score
# as the associated covariate

# get unique observers per sei
dataSeiScore <- distinct(
  dataSubsample, sampling_event_identifier,
  observer_id
) %>%
  # make list column of observers
  mutate(observers = str_split(observer_id, ",")) %>%
  unnest(cols = c(observers)) %>%
  # add numeric observer id
  mutate(numObserver = str_extract(observers, "\\d+")) %>%
  # now get distinct sei and observer id numeric
  distinct(sampling_event_identifier, numObserver)

# now add expertise score to sei
dataSeiScore <- left_join(dataSeiScore, expertiseScore,
  by = "numObserver"
) %>%
  # get max expertise score per sei
  group_by(sampling_event_identifier) %>%
  summarise(expertise = max(score))

# add to dataCovar
dataSubsample <- left_join(dataSubsample, dataSeiScore,
  by = "sampling_event_identifier"
)

# remove data without expertise score
dataSubsample <- filter(dataSubsample, !is.na(expertise))

#' 
#' ## Add climatic and landscape covariates
#' 
#' Reload climate and land cover predictors prepared previously. 
## ----add_landcovars-----------------------------------------------------------

# list landscape covariate stacks
landscape_files <- "data/spatial/landscape_resamp01_km.tif"

# read in as stacks
landscape_data <- stack(landscape_files)

# get proper names
elev_names <- c("elev", "slope", "aspect")
chelsa_names <- c("bio1", "bio12")

names(landscape_data) <- as.character(glue('{c(elev_names, chelsa_names, "landcover")}'))

#' 
#' ## Spatial buffers around selected checklists
#' 
#' Every checklist on eBird is associated with a latitude and longitude. However, the coordinates entered by an observer may not accurately depict the location at which a species was detected. This can occur for two reasons: first, traveling checklists are often associated with a single location along the route travelled by observers; and second, checklist locations could be assigned to a ‘hotspot’ – a location that is marked by eBird as being frequented by multiple observers. In many cases, an observation might be assigned to a hotspot even though the observation was not made at the precise location of the hotspot [@praveenj.2017]. Johnston et al., (2019) showed that a large proportion of observations occurred within a 3km grid, even for those checklists up to 5km in length. Hence to adjust for spatial precision, we considered a minimum radius of 2.5km around each unique locality when sampling environmental covariate values. 
## ----point_buffer-------------------------------------------------------------
# assign neighbourhood radius in m
sample_radius <- 2.5 * 1e3

# get distinct points and make buffer
ebird_buff <- dataSubsample %>%
  ungroup() %>%
  distinct(X, Y) %>%
  mutate(id = 1:nrow(.)) %>%
  crossing(sample_radius) %>%
  arrange(id) %>%
  group_by(sample_radius) %>%
  nest() %>%
  ungroup()


# convert to spatial features
ebird_buff <- mutate(ebird_buff,
  data = map2(
    data, sample_radius,
    function(df, rd) {
      df_sf <- st_as_sf(df, coords = c("X", "Y"), crs = 32643) %>%
        # add long lat
        bind_cols(as_tibble(st_coordinates(.))) %>%
        # rename(longitude = X, latitude = Y) %>%
        # # transform to modis projection
        # st_transform(crs = 32643) %>%
        # buffer to create neighborhood around each point
        st_buffer(dist = rd)
    }
  )
)

#' 
#' ## Spatial buffer-wide covariates
#' 
#' ### Mean climatic covariates
#' 
#' All climatic covariates are sampled by considering the mean values within a 2.5km radius as discussed above and prefixed "am_".
## ----mean_landscape-----------------------------------------------------------
# get area mean for all preds except landcover, which is the last one
env_area_mean <- purrr::map(ebird_buff$data, function(df) {
  stk <- landscape_data[[-dim(landscape_data)[3]]] # removing landcover here
  velstk <- velox(stk)
  dextr <- velstk$extract(
    sp = df, df = TRUE,
    fun = function(x) mean(x, na.rm = T)
  )

  # assign names for joining
  names(dextr) <- c("id", names(stk))
  return(as_tibble(dextr))
})

# join to buffer data
ebird_buff <- ebird_buff %>%
  mutate(data = map2(data, env_area_mean, inner_join, by = "id"))

#' 
#' ### Proportions of land cover type
#' 
#' All land cover covariates were sampled by considering the proportion of each land cover type within a 2.5km radius. 
## ----pland--------------------------------------------------------------------
# get the last element of each stack from the list
# this is the landcover at that resolution
lc_area_prop <- purrr::map(ebird_buff$data, function(df) {
  lc <- landscape_data[[dim(landscape_data)[3]]] # accessing landcover here
  lc_velox <- velox(lc)
  lc_vals <- lc_velox$extract(sp = df, df = TRUE)
  names(lc_vals) <- c("id", "lc")

  # get landcover proportions
  lc_prop <- count(lc_vals, id, lc) %>%
    group_by(id) %>%
    mutate(
      lc = glue('lc_{str_pad(lc, 2, pad = "0")}'),
      prop = n / sum(n)
    ) %>%
    dplyr::select(-n) %>%
    tidyr::pivot_wider(
      names_from = lc,
      values_from = prop,
      values_fill = list(prop = 0)
    ) %>%
    ungroup()

  return(lc_prop)
})

# join to data
ebird_buff <- ebird_buff %>%
  mutate(data = map2(data, lc_area_prop, inner_join, by = "id"))

#' 
#' ### Link environmental covariates to checklists
#' 
## ----land_to_obs--------------------------------------------------------------
# duplicate scale data
data_at_scale <- ebird_buff

# join the full data to landscape samples at each scale
data_at_scale$data <- map(data_at_scale$data, function(df) {
  df <- st_drop_geometry(df)
  df <- inner_join(dataSubsample, df, by = c("X", "Y"))
  return(df)
})

#' 
#' Save data to file.
## ----spit_scale---------------------------------------------------------------
# write to file
pmap(data_at_scale, function(sample_radius, data) {
  write_csv(data, path = glue('data/04_data-covars-{str_pad(sample_radius/1e3, 2, pad = "0")}km.csv'))
  message(glue('export done: data/04_data-covars-{str_pad(sample_radius/1e3, 2, pad = "0")}km.csv'))
})

