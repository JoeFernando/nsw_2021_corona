#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Load libraries
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#


library(data.table)
library(openxlsx)
library(janitor)
library(lubridate)
library(tidyverse)
library(broom)
library(deSolve)
# library(platus)
library(scales)
library(patchwork)


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# New case locations
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
nsw_case_loc <- jsonlite::fromJSON("https://data.nsw.gov.au/data/dataset/0a52e6c1-bc0b-48af-8b45-d791a6d8e289/resource/f3a28eed-8c2a-437b-8ac1-2dab3cf760f9/download/covid-case-locations-20210812-1000.json") %>%
  as.data.frame() %>%
  rename_if(stringr::str_detect(names(.), "data.monitor."), ~stringr::str_remove_all(., "data.monitor.")) %>%
  clean_names() %>%
  
  rename(
    publish_date = date,
    publish_time = time,
    first_detected_date = date_2,
    first_detected_time = time_2
  ) %>%
  
  mutate(
    publish_date = ymd(publish_date),
    first_detected_date = as.Date(first_detected_date, format = '%A %d %B %Y'),
    last_updated_date   = as.Date(last_updated_date,   format = '%A %d %B %Y'),
    transmissionvenues  = parse_number(transmissionvenues)
  ) %>%
  relocate(last_updated_date, .before = first_detected_date)

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Load data
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#


nsw <- read.csv("https://data.nsw.gov.au/data/dataset/aefcde60-3b0c-4bc0-9af1-6fe652944ec2/resource/21304414-1ff1-4243-a5d2-f52778048b29/download/confirmed_cases_table1_location.csv")



df_to_model <- nsw %>% 
  dplyr::group_by(notification_date) %>% 
  dplyr::count(name = "infections") %>% 
  ungroup() %>% 
  mutate(date = ymd(notification_date)) %>% 
  select(date, infections) %>% 
  filter(date >= dmy("01/07/2021"))



country_population <- 8092000 * 0.814 * .1    # people aged 15 and over in NSW is 81.4% of population <http://www.healthstats.nsw.gov.au/Indicator/Dem_pop_age>
                                              # The 0.2 refers to the unvaxed part of the population


filter_from_date <- dmy("01/07/2021")
country_to_model <- "NSW"  
points_to_plot_in_short_plot = 70
days_to_model     = 1:200


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# SIR
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#


SIR <- function(time, state, parameters) {
  par <- as.list(c(state, parameters))
  with(par, {
    dS <- -beta/N * I * S
    dI <- beta/N * I * S - gamma * I
    dR <- gamma * I
    list(c(dS, dI, dR))
  })
}



RSS <- function(parameters) {
  names(parameters) <- c("beta", "gamma")
  out <- ode(y = init, times = Day, func = SIR, parms = parameters)
  fit <- out[ , 3]
  sum((Infected - fit)^2)
}


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
#get input paramenters and generate forecast
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
Infected <- df_to_model$infections
Day      <- 1:(length(Infected))
N        <- country_population


init <- c(S = N-Infected[1], I = Infected[1], R = 0)


Opt <- optim(c(0.5, 0.5), RSS, method = "L-BFGS-B", lower = c(0, 0), upper = c(1, 1)) # optimize with some sensible conditions


Opt_par <- setNames(Opt$par, c("beta", "gamma"))


t   <- days_to_model # time in days
fit <- data.frame(ode(y = init, times = t, func = SIR, parms = Opt_par))



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Generate output df
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#


output_df <- data.frame(
  date = seq(from = filter_from_date, to = (filter_from_date + max(t) - 1), by = "day"),
  forecast_infections = round(fit$I)
) %>% 
  full_join(df_to_model , ., by = "date") %>% 
  rename(actual_infections = infections)



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# Output Stats
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
R0 <- setNames(Opt_par["beta"] / Opt_par["gamma"], "R0")


height_of_pandemic <- output_df %>% 
  filter(forecast_infections == max(forecast_infections)) %>% pull(forecast_infections)


height_of_pandemic_date <- output_df %>% 
  filter(forecast_infections == max(forecast_infections)) %>% pull(date)


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#
# generate plots 
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~#


full_forecast_plot <- output_df %>% 
  ggplot(aes(x = date)) +
  geom_line(aes(y = forecast_infections / 1000), colour = "blue") +
  geom_point(aes(y = actual_infections / 1000), colour = "red") +
  
  geom_vline(xintercept = height_of_pandemic_date, linetype = "dotted") +
  
  annotate(geom = "text", 
           x = height_of_pandemic_date, 
           y = (height_of_pandemic / 1000) / 2, 
           label = str_glue("Max. infections of {comma(height_of_pandemic / 1000, accuracy = 0.01)}k  on {height_of_pandemic_date}"), 
           color = "black", 
           angle = 90,
           vjust = -0.25,
           size = 4) +
  
  
  theme_bw() +
  xlab("") +
  ylab("Number of Infections - Thousands") +
  scale_x_date(breaks = scales::pretty_breaks(n = 12))+   # for one year date labels
  scale_y_continuous(label = comma) +
  labs(title = str_glue("{country_to_model} Corona Virus Infections Forecast"), 
          subtitle = str_glue("Blue line is model Projection and Red Points are Actuals - Current Ro {round(R0, 2)}"),
       caption  = "Source: Data.NSW / NSW COVID-19 cases by location")



blast_off_plot <- output_df %>% 
  slice(1:points_to_plot_in_short_plot) %>% 
  ggplot(aes(x = date)) +
  
  geom_line(aes(y = forecast_infections), colour = "blue") +
  geom_point(aes(y = forecast_infections), colour = "blue", shape = 3) +
  
  geom_point(aes(y = actual_infections), colour = "red") +
  theme_bw() +
  xlab("") +
  ylab("Number of Infections") +
  scale_x_date(breaks = scales::pretty_breaks(n = 12))+   # for one year date labels
  scale_y_continuous(label = comma) +
  labs(title = str_glue("Initial Phase of Infection in {country_to_model} - First {points_to_plot_in_short_plot} forecast points vs. actual"), 
          subtitle = str_glue("Blue line is model Projection and Red Points are Actuals - Current Ro {round(R0, 2)}"),
          caption  = "Source: Data.NSW / NSW COVID-19 cases by location")


p1 <- blast_off_plot + full_forecast_plot + plot_layout(ncol = 1)

# 
# x11()
# plot(p1)

# xlopen(output_df)
