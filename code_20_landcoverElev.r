#### code to get landcover proportion by elevation ####

# load libs
library(data.table); library(raster)
library(stars)
# get data
elevData <- raster("data/elevationHills.tif")
lc <- raster("data/spatial/landcover100m.tif")
elevData <- projectRaster(from = elevData, to = lc, res = res(lc))


# get coords of elev and extract lc
combdata <- coordinates(elevData)
lc_at_coords <- raster::extract(lc, combdata)
combdata <- cbind(combdata, elev = getValues(elevData))
combdata <- cbind(combdata, lc_at_coords)

# set data table and round values
combdata <- data.table(combdata)
combdata[,elev_round:=plyr::round_any(elev, 100)]
combdata <- combdata[!is.na(lc_at_coords) & !is.na(elev_round),.N, 
                     by = list(lc_at_coords, elev_round)
                     ][,prop:=N/sum(N), by = "elev_round"]

# plot in ggplot
library(ggplot2)

ggplot(combdata)+
  geom_tile(aes(x=elev_round, y=factor(lc_at_coords), fill=prop))+
  scale_fill_viridis_c(option = "B")+
  labs(x = "elevation (100m interval)", y = "landcover", title = "landcover proportion ~ elevation",
       caption = Sys.time())+
  ggthemes::theme_few()

ggsave(filename = "figs/fig_lc_elev.png", device = png())

#### checklists per elevation ####
chkdata <- fread("data/eBirdChecklistVars.csv")
# re-read elev instead of reproj
elevData <- raster("data/elevationHills.tif")
chkdata[,elev:=extract(elevData, chkdata[,c("longitude", "latitude")])]
nchk_elev <- chkdata[,elev_round:=plyr::round_any(elev, 100)
        ][,.N, by="elev_round"][!is.na(elev_round)]

# plot and export
ggplot(chkdata)+
  geom_histogram(aes(x = elev), fill = "grey", col = 1, lwd = 0.2)+
  ggthemes::theme_few()+
  labs(x = "elevation (100m interval)", y = "count", title = "N checklists ~ elevation",
       caption = Sys.time())
ggsave(filename = "figs/fig_nchk_elev.png", device = png())