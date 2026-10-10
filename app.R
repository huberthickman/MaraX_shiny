# MaraX live dashboard ---------------------------------------------------------
# Single R process: reads the Gicar serial stream, keeps a rolling in-memory
# window (no database), draws live charts, and plays a sound when the machine
# is ready.
#
# Run:  Rscript -e 'shiny::runApp("/opt/marax", host = "0.0.0.0", port = 3838)'
# Test without the machine: set `simulate: true` in marax.yml.

library(shiny)

`%||%` <- function(a, b) if (is.null(a)) b else a

cfg_path <- Sys.getenv("MARAX_CONFIG", "marax.yml")
cfg <- yaml::read_yaml(cfg_path)

WINDOW_SEC   <- (cfg$window_minutes %||% 30) * 60
READY_HX     <- cfg$ready_hx[[as.character(cfg$temp_setting)]]
STABLE_SEC   <- (cfg$stable_minutes %||% 3) * 60
STABLE_BAND  <- cfg$stable_band %||% 1
STALE_SEC    <- 10   # no data this long -> "No data"
OFF_SEC      <- 30   # no data this long -> machine off, re-arm the alert
GAP_SEC      <- 5    # break plotted lines across gaps longer than this

if (is.null(READY_HX)) stop("No ready_hx entry for temp_setting '", cfg$temp_setting, "'")

# Colours (dark kitchen theme) --------------------------------------------------
COL <- list(
  bg      = "#1a1a19", panel = "#222221", grid = "#33332f",
  text    = "#f0efec", text2 = "#c3c2b7", muted = "#8a8984",
  hx      = "#3987e5",                 # series 1
  steam   = "#d95926",                 # series 2
  ready   = "#0ca30c",                 # status: good
  heat_bg = adjustcolor("#c3c2b7", alpha.f = 0.10),
  duty    = "#8a8984"
)

# Rolling buffer ------------------------------------------------------------
store <- new.env()
store$df <- data.frame(
  ts = as.POSIXct(numeric(0), origin = "1970-01-01"),
  mode = character(), steam = numeric(), steam_target = numeric(),
  hx = numeric(), boost = numeric(), heat = numeric()
)
store$last_rx <- NULL

add_reading <- function(r) {
  now <- Sys.time()
  df  <- rbind(store$df, data.frame(ts = now, r))
  store$df <- df[df$ts > now - WINDOW_SEC, , drop = FALSE]
  store$last_rx <- now
  check_ready()
}

recent_readings <- function(minutes) {
  df <- store$df
  df[df$ts > Sys.time() - minutes * 60, , drop = FALSE]
}

# Parsing -------------------------------------------------------------------
# V1 line: C1.19,116,124,093,0840,1  (mode+fw, steam, steam target, HX, boost, heater)
parse_line <- function(line) {
  f <- trimws(strsplit(trimws(line), ",", fixed = TRUE)[[1]])
  if (length(f) < 6 || !grepl("^[CV][0-9.]+$", f[1])) return(NULL)
  n <- suppressWarnings(as.numeric(f[2:6]))
  if (anyNA(n)) return(NULL)
  if (any(n[1:3] < 0 | n[1:3] > 160) || n[4] < 0 || !n[5] %in% c(0, 1)) return(NULL)
  list(mode = substr(f[1], 1, 1), steam = n[1], steam_target = n[2],
       hx = n[3], boost = n[4], heat = n[5])
}

# Ready alert -----------------------------------------------------------------
alert <- new.env()
alert$state <- "off"          # off -> warming -> ready
alert$ready_at <- NULL

play_alert <- function() {
  message("MaraX ready at ", format(Sys.time(), "%H:%M:%S"))
  f <- cfg$sound_file
  if (isTRUE(cfg$sound) && !is.null(f) && file.exists(f)) {
    system2(cfg$sound_player %||% "pw-play", shQuote(f),
            wait = FALSE, stdout = FALSE, stderr = FALSE)
  }
}

check_ready <- function() {
  df <- store$df
  last <- df[nrow(df), ]
  if (alert$state == "off") { alert$state <- "warming"; alert$saw_cold <- FALSE }
  if (alert$state != "warming") return(invisible())
  # Only crow if we actually watched a warm-up (not when the app restarts
  # while the machine is already hot).
  if (last$boost > 0 || last$hx < READY_HX - 5) alert$saw_cold <- TRUE

  span   <- as.numeric(difftime(last$ts, df$ts[1], units = "secs"))
  recent <- df$hx[df$ts >= last$ts - STABLE_SEC]
  if (last$boost == 0 && span >= STABLE_SEC &&
      min(recent) >= READY_HX && diff(range(recent)) <= STABLE_BAND) {
    alert$state <- "ready"
    alert$ready_at <- last$ts
    if (isTRUE(alert$saw_cold)) play_alert()
  }
}

watchdog <- function() {
  if (!is.null(store$last_rx) &&
      difftime(Sys.time(), store$last_rx, units = "secs") > OFF_SEC) {
    alert$state <- "off"       # machine switched off: re-arm for next warm-up
    alert$ready_at <- NULL
  }
}

# Serial input ----------------------------------------------------------------
PORT <- cfg$port %||% "/dev/ttyUSB0"
serial <- new.env()
serial$con <- NULL

open_serial <- function() {
  if (!file.exists(PORT)) return(FALSE)
  rc <- system2("stty", c("-F", PORT, "9600", "cs8", "-cstopb", "-parenb", "raw", "-echo"),
                stdout = FALSE, stderr = FALSE)
  if (rc != 0) return(FALSE)
  serial$con <- tryCatch(file(PORT, open = "r", blocking = FALSE),
                         error = function(e) NULL)
  !is.null(serial$con)
}

close_serial <- function() {
  if (!is.null(serial$con)) try(close(serial$con), silent = TRUE)
  serial$con <- NULL
}

poll_serial <- function() {
  if (!is.null(serial$con) && !file.exists(PORT)) close_serial()   # unplugged
  if (is.null(serial$con) && !open_serial()) {
    watchdog()
    later::later(poll_serial, 5)                                   # retry
    return(invisible())
  }
  # Non-blocking text connection: incomplete lines are pushed back until complete.
  lines <- tryCatch(readLines(serial$con, warn = FALSE),
                    error = function(e) { close_serial(); character() })
  for (l in lines) {
    r <- parse_line(l)
    if (!is.null(r)) add_reading(r)
  }
  watchdog()
  later::later(poll_serial, 0.25)
}

# Simulator (simulate: true) ----------------------------------------------------
sim <- new.env()
sim$t0 <- Sys.time()

sim_line <- function() {
  t <- as.numeric(difftime(Sys.time(), sim$t0, units = "secs")) * (cfg$sim_speed %||% 10)
  target <- 124
  base   <- target - (target - 22) * exp(-t / 240)
  osc    <- 1.5 * sin(t / 40) * (1 - exp(-t / 240))
  heat   <- as.integer(base < target - 3 || cos(t / 40) > 0)
  hx_end <- READY_HX + 2
  hx     <- hx_end - (hx_end - 22) * exp(-t / 420)
  ph     <- t %% 600
  if (t > 2400 && ph < 30) hx <- hx - 6 * sin(pi * ph / 30)       # a "shot"
  sprintf("%s1.19,%03d,%03d,%03d,%04d,%d", cfg$sim_mode %||% "C",
          round(base + osc), target, round(hx), max(0, round(1200 - t)), heat)
}

poll_sim <- function() {
  r <- parse_line(sim_line())
  if (!is.null(r)) add_reading(r)
  later::later(poll_sim, 0.5)
}

if (isTRUE(cfg$simulate)) poll_sim() else poll_serial()

# Chart helpers -----------------------------------------------------------------
# Insert NA breaks so lines don't bridge power-off gaps.
gapped <- function(ts, y) {
  t <- as.numeric(ts)
  br <- which(diff(t) > GAP_SEC)
  if (!length(br)) return(list(x = ts, y = y))
  ord <- order(c(seq_along(t), br + 0.5))
  list(x = as.POSIXct(c(t, t[br] + 1)[ord], origin = "1970-01-01"),
       y = c(y, rep(NA, length(br)))[ord])
}

# Share of time the heater was on over the trailing `sec` seconds, in %.
rolling_duty <- function(df, sec = 60) {
  t  <- as.numeric(df$ts)
  cs <- c(0, cumsum(df$heat))
  i  <- seq_along(t)
  j  <- findInterval(t - sec, t)
  100 * (cs[i + 1] - cs[j + 1]) / (i - j)
}

setup_par <- function(right = 6) {
  par(bg = COL$bg, fg = COL$grid, col.axis = COL$text2, col.lab = COL$text2,
      mar = c(2.2, 3.2, 0.6, right), las = 1, cex.axis = 1.05, mgp = c(2, 0.5, 0),
      tcl = -0.2, family = "sans")
}

time_axis <- function(xlim) {
  at <- pretty(xlim, n = 6)
  axis.POSIXct(1, x = xlim, at = at, format = "%H:%M", col = NA, col.ticks = COL$grid)
}

empty_plot <- function(msg) {
  setup_par()
  plot.new()
  text(0.5, 0.5, msg, col = COL$muted, cex = 1.5)
}

draw_temps <- function(df, xlim) {
  setup_par()
  ylim <- range(c(df$hx, df$steam, df$steam_target, READY_HX)) + c(-3, 3)
  plot(NA, xlim = xlim, ylim = ylim, xaxt = "n", xlab = "", ylab = "", frame.plot = FALSE)
  usr <- par("usr")

  # Heater-on periods as faint bands
  r <- rle(df$heat == 1)
  ends <- cumsum(r$lengths); starts <- ends - r$lengths + 1
  on <- which(r$values)
  if (length(on)) {
    stop_i <- pmin(ends[on] + 1, nrow(df))
    rect(df$ts[starts[on]], usr[3], df$ts[stop_i], usr[4], col = COL$heat_bg, border = NA)
  }

  abline(h = pretty(ylim), col = COL$grid, lwd = 1)
  time_axis(xlim)

  # Ready threshold
  abline(h = READY_HX, col = COL$ready, lty = 3, lwd = 1.5)
  text(usr[1], READY_HX, sprintf(" ready ≥ %d°", READY_HX),
       adj = c(0, -0.4), col = COL$text2, cex = 0.95)

  st <- gapped(df$ts, df$steam_target)
  lines(st$x, st$y, col = COL$steam, lty = 2, lwd = 1)
  s <- gapped(df$ts, df$steam)
  lines(s$x, s$y, col = COL$steam, lwd = 2)
  h <- gapped(df$ts, df$hx)
  lines(h$x, h$y, col = COL$hx, lwd = 2.5)

  # Direct labels at the right edge (text in text colour, swatch carries identity)
  last <- df[nrow(df), ]
  lab_y <- c(last$hx, last$steam)
  if (abs(diff(lab_y)) < 0.06 * diff(ylim)) lab_y <- mean(lab_y) + c(-1, 1) * 0.03 * diff(ylim)
  par(xpd = NA)
  x_lab <- usr[2] + 0.01 * diff(usr[1:2])
  points(rep(x_lab, 2), lab_y, pch = 15, cex = 1.3, col = c(COL$hx, COL$steam))
  text(x_lab, lab_y, sprintf("  %s %d°", c("HX", "Steam"), round(c(last$hx, last$steam))),
       adj = 0, col = COL$text, cex = 1.05)
  par(xpd = FALSE)
}

draw_duty <- function(df, xlim) {
  setup_par()
  d <- rolling_duty(df)
  plot(NA, xlim = xlim, ylim = c(0, 100), xaxt = "n", yaxt = "n",
       xlab = "", ylab = "", frame.plot = FALSE)
  abline(h = c(0, 50, 100), col = COL$grid)
  axis(2, at = c(0, 50, 100), labels = c("0", "50", "100%"), col = NA)
  time_axis(xlim)
  g <- gapped(df$ts, d)
  ok <- !is.na(g$y)
  polygon(c(g$x[ok][1], g$x[ok], g$x[ok][sum(ok)]), c(0, g$y[ok], 0),
          col = adjustcolor(COL$duty, 0.35), border = NA)
  lines(g$x, g$y, col = COL$duty, lwd = 2)
  par(xpd = NA)
  text(par("usr")[2] + 0.01 * diff(par("usr")[1:2]), tail(d, 1),
       sprintf("  %d%%", round(tail(d, 1))), adj = 0, col = COL$text, cex = 1.05)
  par(xpd = FALSE)
}

# UI ------------------------------------------------------------------------------
css <- sprintf("
html, body { background:%1$s; color:%2$s; margin:0; overflow:hidden;
  font-family: system-ui, sans-serif; -webkit-user-select:none; user-select:none; }
.container-fluid { padding: 10px 16px; }
.tiles { display:grid; grid-template-columns: 1.4fr 1.2fr 1fr 1fr 1.5fr; gap:10px; }
.tile { background:%3$s; border-radius:10px; padding:8px 14px; min-height:92px; }
.tile .lbl { font-size:15px; color:%4$s; }
.tile .val { font-size:44px; font-weight:600; line-height:1.15; font-variant-numeric: tabular-nums; }
.tile .sub { font-size:15px; color:%4$s; }
.swatch { display:inline-block; width:12px; height:12px; border-radius:2px; margin-right:6px; }
.tile.ready { box-shadow: inset 0 0 0 3px %5$s; }
.toolbar { display:flex; align-items:center; gap:10px; margin:10px 0 2px; }
.toolbar .title { font-size:16px; color:%4$s; margin-right:auto; }
.toolbar .btn { min-width:72px; min-height:44px; font-size:17px; border-radius:8px;
  background:%3$s; color:%2$s; border:1px solid #3a3a37; }
.toolbar .btn.active { background:#3a3a37; border-color:%4$s; }
.chart-title { font-size:15px; color:%4$s; margin:4px 0 0 4px; }
", COL$bg, COL$text, COL$panel, COL$text2, COL$ready)

ui <- fluidPage(
  tags$head(tags$style(HTML(css)), tags$title("MaraX")),
  uiOutput("tiles"),
  div(class = "toolbar",
      span(class = "title", "Temperatures (°C) — shaded = heater on"),
      uiOutput("window_buttons", inline = TRUE)),
  plotOutput("temp_plot", height = "370px"),
  div(class = "chart-title", "Heater duty, trailing 60 s"),
  plotOutput("duty_plot", height = "130px")
)

# Server ----------------------------------------------------------------------------
server <- function(input, output, session) {
  win <- reactiveVal(min(15, WINDOW_SEC / 60))
  choices <- c(5, 15, 30)[c(5, 15, 30) <= WINDOW_SEC / 60]

  output$window_buttons <- renderUI({
    lapply(choices, function(m) {
      actionButton(paste0("w", m), paste(m, "min"),
                   class = if (m == win()) "active" else NULL)
    })
  })
  lapply(choices, function(m) observeEvent(input[[paste0("w", m)]], win(m)))

  tile <- function(lbl, val, sub = NULL, swatch = NULL, class = NULL) {
    div(class = paste("tile", class),
        div(class = "lbl",
            if (!is.null(swatch)) span(class = "swatch", style = paste0("background:", swatch)),
            lbl),
        div(class = "val", val),
        if (!is.null(sub)) div(class = "sub", sub))
  }

  output$tiles <- renderUI({
    invalidateLater(1000)
    df <- store$df
    stale <- is.null(store$last_rx) ||
      difftime(Sys.time(), store$last_rx, units = "secs") > STALE_SEC
    if (!nrow(df) || stale) {
      return(div(class = "tiles",
                 tile("HX", "—", swatch = COL$hx),
                 tile("Steam boiler", "—", swatch = COL$steam),
                 tile("Mode", "—"), tile("Heater", "—"),
                 tile("Status", "No data", if (isTRUE(cfg$simulate)) "simulator" else PORT)))
    }
    last <- df[nrow(df), ]
    status <- if (alert$state == "ready") {
      tile("Status", "Ready ☕", paste("since", format(alert$ready_at, "%H:%M")), class = "ready")
    } else if (last$boost > 0) {
      tile("Status", sprintf("%d:%02d", last$boost %/% 60, last$boost %% 60), "fast-heat boost")
    } else {
      tile("Status", "Warming", sprintf("waiting for HX ≥ %d°, stable", READY_HX))
    }
    div(class = "tiles",
        tile("HX", sprintf("%d°", round(last$hx)), swatch = COL$hx),
        tile("Steam boiler", sprintf("%d°", round(last$steam)),
             sprintf("target %d°", round(last$steam_target)), swatch = COL$steam),
        tile("Mode", if (last$mode == "C") "Coffee" else "Steam",
             paste("switch", cfg$temp_setting)),
        tile("Heater", if (last$heat == 1) "ON" else "off"),
        status)
  })

  output$temp_plot <- renderPlot({
    invalidateLater(2000)
    df <- recent_readings(win())
    if (nrow(df) < 2) return(empty_plot("Waiting for data…"))
    draw_temps(df, c(Sys.time() - win() * 60, Sys.time()))
  }, res = 96, bg = COL$bg)

  output$duty_plot <- renderPlot({
    invalidateLater(2000)
    df <- recent_readings(win())
    if (nrow(df) < 2) return(empty_plot(""))
    draw_duty(df, c(Sys.time() - win() * 60, Sys.time()))
  }, res = 96, bg = COL$bg)
}

shinyApp(ui, server)