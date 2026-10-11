# MaraX live dashboard ---------------------------------------------------------
# Single R process: reads the Gicar serial stream, keeps a rolling in-memory
# window (no database), draws live charts, and plays a sound when the machine
# is ready.
#
# Run:  Rscript -e 'shiny::runApp("~/marax", port = 3838)'
# Test without the machine: set `simulate: true` in marax.yml.
# See README.md for setup.

library(shiny)
library(yaml) # config file
library(later) # background polling of the serial port
library(beepr) # ready sound
# Serial port: Windows needs the 'serial' package; macOS/Linux use base R + stty,
# so 'serial' (which pulls in Tcl/Tk) is only loaded on Windows.
if (.Platform$OS.type == "windows") {
  library(serial)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

cfg_path <- Sys.getenv("MARAX_CONFIG", "marax.yml")
cfg <- yaml::read_yaml(cfg_path)

WINDOW_SEC <- (cfg$window_minutes %||% 30) * 60
READY_HX <- cfg$ready_hx[[as.character(cfg$temp_setting)]]
STABLE_SEC <- (cfg$stable_minutes %||% 3) * 60
STABLE_BAND <- cfg$stable_band %||% 1
STALE_SEC <- 10 # no data this long -> "No data"
OFF_SEC <- 30 # no data this long -> machine off, re-arm the alert
GAP_SEC <- 5 # break plotted lines across gaps longer than this

if (is.null(READY_HX)) {
  stop("No ready_hx entry for temp_setting '", cfg$temp_setting, "'")
}

# Colours (dark kitchen theme) --------------------------------------------------
COL <- list(
  bg = "#1a1a19",
  panel = "#222221",
  grid = "#33332f",
  text = "#f0efec",
  text2 = "#c3c2b7",
  muted = "#8a8984",
  hx = "#3987e5", # series 1
  steam = "#d95926", # series 2
  ready = "#0ca30c", # status: good
  heat_bg = adjustcolor("#c3c2b7", alpha.f = 0.10),
  duty = "#8a8984"
)

# Rolling buffer ------------------------------------------------------------
store <- new.env()
store$df <- data.frame(
  ts = as.POSIXct(numeric(0), origin = "1970-01-01"),
  mode = character(),
  steam = numeric(),
  steam_target = numeric(),
  hx = numeric(),
  boost = numeric(),
  heat = numeric()
)
store$last_rx <- NULL

add_reading <- function(r) {
  now <- Sys.time()
  df <- rbind(store$df, data.frame(ts = now, r))
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
  if (length(f) < 6 || !grepl("^[CV][0-9.]+$", f[1])) {
    return(NULL)
  }
  n <- suppressWarnings(as.numeric(f[2:6]))
  if (anyNA(n)) {
    return(NULL)
  }
  if (any(n[1:3] < 0 | n[1:3] > 160) || n[4] < 0 || !n[5] %in% c(0, 1)) {
    return(NULL)
  }
  list(
    mode = substr(f[1], 1, 1),
    steam = n[1],
    steam_target = n[2],
    hx = n[3],
    boost = n[4],
    heat = n[5]
  )
}

# Ready alert -----------------------------------------------------------------
alert <- new.env()
alert$state <- "off" # off -> warming -> ready
alert$ready_at <- NULL

# cfg$sound: a beepr sound number or name (7 = "shotgun"), a path to a .wav,
# or false to stay quiet.
play_alert <- function() {
  message("MaraX ready at ", format(Sys.time(), "%H:%M:%S"))
  snd <- cfg$sound %||% 7
  if (isFALSE(snd)) {
    return(invisible())
  }
  tryCatch(
    beepr::beep(snd),
    error = function(e) message("Sound failed: ", conditionMessage(e)),
    warning = function(w) message("Sound warning: ", conditionMessage(w))
  )
}

check_ready <- function() {
  df <- store$df
  last <- df[nrow(df), ]
  if (alert$state == "off") {
    alert$state <- "warming"
    alert$saw_cold <- FALSE
  }
  if (alert$state != "warming") {
    return(invisible())
  }
  # Only crow if we actually watched a warm-up (not when the app restarts
  # while the machine is already hot).
  if (last$boost > 0 || last$hx < READY_HX - 5) {
    alert$saw_cold <- TRUE
  }

  span <- as.numeric(difftime(last$ts, df$ts[1], units = "secs"))
  recent <- df$hx[df$ts >= last$ts - STABLE_SEC]
  if (
    last$boost == 0 &&
      span >= STABLE_SEC &&
      min(recent) >= READY_HX &&
      diff(range(recent)) <= STABLE_BAND
  ) {
    alert$state <- "ready"
    alert$ready_at <- last$ts
    if (isTRUE(alert$saw_cold)) play_alert()
  }
}

watchdog <- function() {
  if (
    !is.null(store$last_rx) &&
      difftime(Sys.time(), store$last_rx, units = "secs") > OFF_SEC
  ) {
    alert$state <- "off" # machine switched off: re-arm for next warm-up
    alert$ready_at <- NULL
  }
}

# Serial input ----------------------------------------------------------------
# port: a device path / COM name, or "auto" to use the USB serial adapter found
# (Linux /dev/ttyUSB*, macOS /dev/cu.usbserial*, Windows COMn).
#
# macOS/Linux: base R file connection + stty, no extra packages.
# Windows:     the CRAN 'serial' package (no /dev or stty there).
IS_WIN <- .Platform$OS.type == "windows"
IS_MAC <- Sys.info()[["sysname"]] == "Darwin"

PORT_CFG <- cfg$port %||% "auto"
ser <- new.env()
ser$con <- NULL
ser$port <- PORT_CFG
ser$partial <- ""

find_port <- function() {
  if (PORT_CFG != "auto") {
    return(PORT_CFG)
  }
  if (IS_WIN) {
    # USB adapters get the higher COM numbers; COM1 is often a built-in port.
    p <- tryCatch(serial::listPorts(), error = function(e) character())
    p <- grep("^COM[0-9]+$", p, value = TRUE)
    p <- p[order(as.integer(sub("COM", "", p)))]
    return(if (length(p)) tail(p, 1) else "auto (none found)")
  }
  cands <- Sys.glob(c(
    "/dev/ttyUSB*",
    "/dev/ttyACM*",
    "/dev/cu.usbserial*",
    "/dev/cu.wchusbserial*",
    "/dev/cu.usbmodem*"
  ))
  if (length(cands)) cands[1] else "auto (none found)"
}

port_present <- function(p) {
  if (IS_WIN) grepl("^COM[0-9]+$", p) else file.exists(p)
}

open_serial <- function() {
  ser$port <- find_port()
  ser$partial <- ""
  if (!port_present(ser$port)) {
    return(FALSE)
  }

  if (IS_WIN) {
    ser$con <- tryCatch(
      {
        con <- serial::serialConnection(
          name = "marax",
          port = ser$port,
          mode = "9600,n,8,1",
          buffering = "none",
          newline = 0,
          translation = "auto",
          handshake = "none"
        )
        open(con)
        con
      },
      error = function(e) NULL
    )
    return(!is.null(ser$con))
  }

  # Open first, then set the line speed while R holds the port open:
  # macOS resets the settings when the last handle closes.
  ser$con <- tryCatch(
    file(ser$port, open = "r", blocking = FALSE),
    error = function(e) NULL
  )
  if (is.null(ser$con)) {
    return(FALSE)
  }
  rc <- system2(
    "stty",
    c(
      if (IS_MAC) "-f" else "-F",
      ser$port,
      "9600",
      "cs8",
      "-cstopb",
      "-parenb",
      "raw",
      "-echo"
    ),
    stdout = FALSE,
    stderr = FALSE
  )
  if (rc != 0) {
    close_serial()
    return(FALSE)
  }
  TRUE
}

close_serial <- function() {
  if (!is.null(ser$con)) {
    try(close(ser$con), silent = TRUE)
  }
  ser$con <- NULL
}

# Return the complete lines received since the last call.
read_serial_lines <- function() {
  if (!IS_WIN) {
    # Non-blocking text connection: incomplete lines are pushed back until complete.
    return(readLines(ser$con, warn = FALSE))
  }
  # Windows: 'serial' hands back whatever bytes arrived; split into lines ourselves.
  txt <- serial::read.serialConnection(ser$con)
  if (!length(txt) || !nzchar(txt)) {
    return(character())
  }
  buf <- paste0(ser$partial, txt)
  parts <- strsplit(buf, "[\r\n]+")[[1]]
  if (grepl("[\r\n]$", buf)) {
    ser$partial <- ""
  } else {
    ser$partial <- tail(parts, 1)
    parts <- head(parts, -1)
    if (nchar(ser$partial) > 200) ser$partial <- "" # junk, drop it
  }
  parts[nzchar(parts)]
}

poll_serial <- function() {
  if (!is.null(ser$con) && !port_present(ser$port)) {
    close_serial()
  } # unplugged
  if (is.null(ser$con) && !open_serial()) {
    watchdog()
    later::later(poll_serial, 5) # retry
    return(invisible())
  }
  lines <- tryCatch(read_serial_lines(), error = function(e) {
    close_serial()
    character()
  })
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
  t <- as.numeric(difftime(Sys.time(), sim$t0, units = "secs")) *
    (cfg$sim_speed %||% 10)
  target <- 124
  base <- target - (target - 22) * exp(-t / 240)
  osc <- 1.5 * sin(t / 40) * (1 - exp(-t / 240))
  heat <- as.integer(base < target - 3 || cos(t / 40) > 0)
  hx_end <- READY_HX + 2
  hx <- hx_end - (hx_end - 22) * exp(-t / 420)
  ph <- t %% 600
  # A simulated "shot" every 10 min, starting after the machine has gone ready
  # (at sim_speed 10, ready fires ~6 min of real time after start).
  if (t > 4800 && ph < 30) {
    hx <- hx - 6 * sin(pi * ph / 30)
  }
  sprintf(
    "%s1.19,%03d,%03d,%03d,%04d,%d",
    cfg$sim_mode %||% "C",
    round(base + osc),
    target,
    round(hx),
    max(0, round(1200 - t)),
    heat
  )
}

poll_sim <- function() {
  r <- parse_line(sim_line())
  if (!is.null(r)) {
    add_reading(r)
  }
  later::later(poll_sim, 0.5)
}

if (isTRUE(cfg$simulate)) {
  poll_sim()
} else {
  poll_serial()
}

# Chart helpers -----------------------------------------------------------------
# Insert NA breaks so lines don't bridge power-off gaps.
gapped <- function(ts, y) {
  t <- as.numeric(ts)
  br <- which(diff(t) > GAP_SEC)
  if (!length(br)) {
    return(list(x = ts, y = y))
  }
  ord <- order(c(seq_along(t), br + 0.5))
  list(
    x = as.POSIXct(c(t, t[br] + 1)[ord], origin = "1970-01-01"),
    y = c(y, rep(NA, length(br)))[ord]
  )
}

# Share of time the heater was on over the trailing `sec` seconds, in %.
rolling_duty <- function(df, sec = 60) {
  t <- as.numeric(df$ts)
  cs <- c(0, cumsum(df$heat))
  i <- seq_along(t)
  j <- findInterval(t - sec, t)
  100 * (cs[i + 1] - cs[j + 1]) / (i - j)
}

setup_par <- function(right = 6) {
  par(
    bg = COL$bg,
    fg = COL$grid,
    col.axis = COL$text2,
    col.lab = COL$text2,
    mar = c(2.2, 3.2, 0.6, right),
    las = 1,
    cex.axis = 1.05,
    mgp = c(2, 0.5, 0),
    tcl = -0.2,
    family = "sans"
  )
}

time_axis <- function(xlim) {
  at <- pretty(xlim, n = 6)
  axis.POSIXct(
    1,
    x = xlim,
    at = at,
    format = "%H:%M",
    col = NA,
    col.ticks = COL$grid
  )
}

empty_plot <- function(msg) {
  setup_par()
  plot.new()
  text(0.5, 0.5, msg, col = COL$muted, cex = 1.5)
}

draw_temps <- function(df, xlim) {
  setup_par()
  ylim <- range(c(df$hx, df$steam, df$steam_target, READY_HX)) + c(-3, 3)
  plot(
    NA,
    xlim = xlim,
    ylim = ylim,
    xaxt = "n",
    xlab = "",
    ylab = "",
    frame.plot = FALSE
  )
  usr <- par("usr")

  # Heater-on periods as faint bands
  r <- rle(df$heat == 1)
  ends <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1
  on <- which(r$values)
  if (length(on)) {
    stop_i <- pmin(ends[on] + 1, nrow(df))
    rect(
      df$ts[starts[on]],
      usr[3],
      df$ts[stop_i],
      usr[4],
      col = COL$heat_bg,
      border = NA
    )
  }

  abline(h = pretty(ylim), col = COL$grid, lwd = 1)
  time_axis(xlim)

  # Ready threshold
  abline(h = READY_HX, col = COL$ready, lty = 3, lwd = 1.5)
  text(
    usr[1],
    READY_HX,
    sprintf(" ready ≥ %d°", READY_HX),
    adj = c(0, -0.4),
    col = COL$text2,
    cex = 0.95
  )

  st <- gapped(df$ts, df$steam_target)
  lines(st$x, st$y, col = COL$steam, lty = 2, lwd = 1)
  s <- gapped(df$ts, df$steam)
  lines(s$x, s$y, col = COL$steam, lwd = 2)
  h <- gapped(df$ts, df$hx)
  lines(h$x, h$y, col = COL$hx, lwd = 2.5)

  # Direct labels at the right edge (text in text colour, swatch carries identity)
  last <- df[nrow(df), ]
  lab_y <- c(last$hx, last$steam)
  if (abs(diff(lab_y)) < 0.06 * diff(ylim)) {
    lab_y <- mean(lab_y) + c(-1, 1) * 0.03 * diff(ylim)
  }
  par(xpd = NA)
  x_lab <- usr[2] + 0.01 * diff(usr[1:2])
  points(rep(x_lab, 2), lab_y, pch = 15, cex = 1.3, col = c(COL$hx, COL$steam))
  text(
    x_lab,
    lab_y,
    sprintf("  %s %d°", c("HX", "Steam"), round(c(last$hx, last$steam))),
    adj = 0,
    col = COL$text,
    cex = 1.05
  )
  par(xpd = FALSE)
}

draw_duty <- function(df, xlim) {
  setup_par()
  d <- rolling_duty(df)
  plot(
    NA,
    xlim = xlim,
    ylim = c(0, 100),
    xaxt = "n",
    yaxt = "n",
    xlab = "",
    ylab = "",
    frame.plot = FALSE
  )
  abline(h = c(0, 50, 100), col = COL$grid)
  axis(2, at = c(0, 50, 100), labels = c("0", "50", "100%"), col = NA)
  time_axis(xlim)
  g <- gapped(df$ts, d)
  ok <- !is.na(g$y)
  polygon(
    c(g$x[ok][1], g$x[ok], g$x[ok][sum(ok)]),
    c(0, g$y[ok], 0),
    col = adjustcolor(COL$duty, 0.35),
    border = NA
  )
  lines(g$x, g$y, col = COL$duty, lwd = 2)
  par(xpd = NA)
  text(
    par("usr")[2] + 0.01 * diff(par("usr")[1:2]),
    tail(d, 1),
    sprintf("  %d%%", round(tail(d, 1))),
    adj = 0,
    col = COL$text,
    cex = 1.05
  )
  par(xpd = FALSE)
}

# UI ------------------------------------------------------------------------------
css <- sprintf(
  "
/* Laid out for 1366x768 (16:9): tiles in a left column, charts fill the rest.
   Everything is sized from the viewport, so nothing scrolls or gets clipped,
   whether or not the browser shows its toolbar. */
html, body { height:100%%; background:%1$s; color:%2$s; margin:0; overflow:hidden;
  font-family: system-ui, sans-serif; -webkit-user-select:none; user-select:none; }
.app { display:grid; grid-template-columns: clamp(250px, 23vw, 340px) 1fr;
  gap:12px; height:100vh; padding:10px 12px; box-sizing:border-box; }

/* Left column: status on top, then HX, steam, and a mode/heater pair */
.side { display:grid; grid-template-rows: 1.15fr 1.15fr 1fr 0.8fr; gap:10px; min-height:0; }
.pair { display:grid; grid-template-columns: 1fr 1fr; gap:10px; min-height:0; }
.tile { background:%3$s; border-radius:10px; padding:8px 14px; min-height:0; overflow:hidden;
  display:flex; flex-direction:column; justify-content:center; }
.tile .lbl { font-size:clamp(13px, 2vh, 17px); color:%4$s; }
.tile .val { font-size:clamp(30px, 6.5vh, 58px); font-weight:600; line-height:1.1;
  font-variant-numeric: tabular-nums; white-space:nowrap; }
.tile.big .val { font-size:clamp(40px, 9vh, 76px); }
.pair .tile .val { font-size:clamp(20px, 3.8vh, 32px); }
.tile .sub { font-size:clamp(12px, 1.9vh, 16px); color:%4$s; }
.swatch { display:inline-block; width:12px; height:12px; border-radius:2px; margin-right:6px; }
.tile.ready { box-shadow: inset 0 0 0 3px %5$s; }

/* Right column: toolbar, temperature chart (3 parts), duty chart (1 part) */
.main { display:flex; flex-direction:column; min-width:0; min-height:0; }
.toolbar { flex:0 0 auto; display:flex; align-items:center; gap:8px; margin-bottom:4px; }
.toolbar .title { font-size:clamp(13px, 2vh, 16px); color:%4$s; margin-right:auto; }
.toolbar .btn { min-width:70px; min-height:42px; font-size:16px; border-radius:8px;
  background:%3$s; color:%2$s; border:1px solid #3a3a37; padding:4px 10px; }
.toolbar .btn.active { background:#3a3a37; border-color:%4$s; }
.chart { min-height:0; }
.chart.temp { flex:3 1 0; }
.chart.duty { flex:1 1 0; }
.chart-title { flex:0 0 auto; font-size:clamp(12px, 1.9vh, 15px); color:%4$s; margin:4px 0 0 4px; }
",
  COL$bg,
  COL$text,
  COL$panel,
  COL$text2,
  COL$ready
)

ui <- tagList(
  tags$head(
    tags$style(HTML(css)),
    tags$title("MaraX"),
    tags$meta(
      name = "viewport",
      content = "width=device-width, initial-scale=1"
    )
  ),
  div(
    class = "app",
    uiOutput("tiles", class = "side"),
    div(
      class = "main",
      div(
        class = "toolbar",
        span(class = "title", "Temperatures (°C) — shaded = heater on"),
        uiOutput("window_buttons", inline = TRUE),
        actionButton("test_sound", "\U0001F514 Test")
      ),
      div(class = "chart temp", plotOutput("temp_plot", height = "100%")),
      div(class = "chart-title", "Heater duty, trailing 60 s"),
      div(class = "chart duty", plotOutput("duty_plot", height = "100%"))
    )
  )
)
ui <- bootstrapPage(ui)

# Server ----------------------------------------------------------------------------
server <- function(input, output, session) {
  win <- reactiveVal(min(15, WINDOW_SEC / 60))
  choices <- c(5, 15, 30)[c(5, 15, 30) <= WINDOW_SEC / 60]

  output$window_buttons <- renderUI({
    lapply(choices, function(m) {
      actionButton(
        paste0("w", m),
        paste(m, "min"),
        class = if (m == win()) "active" else NULL
      )
    })
  })
  lapply(choices, function(m) observeEvent(input[[paste0("w", m)]], win(m)))
  observeEvent(input$test_sound, play_alert())

  tile <- function(lbl, val, sub = NULL, swatch = NULL, class = NULL) {
    div(
      class = paste("tile", class),
      div(
        class = "lbl",
        if (!is.null(swatch)) {
          span(class = "swatch", style = paste0("background:", swatch))
        },
        lbl
      ),
      div(class = "val", val),
      if (!is.null(sub)) div(class = "sub", sub)
    )
  }

  output$tiles <- renderUI({
    invalidateLater(1000)
    df <- store$df
    stale <- is.null(store$last_rx) ||
      difftime(Sys.time(), store$last_rx, units = "secs") > STALE_SEC
    if (!nrow(df) || stale) {
      return(tagList(
        tile(
          "Status",
          "No data",
          if (isTRUE(cfg$simulate)) "simulator" else ser$port
        ),
        tile("HX", "—", swatch = COL$hx, class = "big"),
        tile("Steam boiler", "—", swatch = COL$steam),
        div(class = "pair", tile("Mode", "—"), tile("Heater", "—"))
      ))
    }
    last <- df[nrow(df), ]
    status <- if (alert$state == "ready") {
      tile(
        "Status",
        "Ready ☕",
        paste("since", format(alert$ready_at, "%H:%M")),
        class = "ready"
      )
    } else if (last$boost > 0) {
      tile(
        "Status",
        sprintf("%d:%02d", last$boost %/% 60, last$boost %% 60),
        "fast-heat boost"
      )
    } else {
      tile("Status", "Warming", sprintf("until HX ≥ %d°, steady", READY_HX))
    }
    tagList(
      status,
      tile(
        "HX",
        sprintf("%d°", round(last$hx)),
        swatch = COL$hx,
        class = "big"
      ),
      tile(
        "Steam boiler",
        sprintf("%d°", round(last$steam)),
        sprintf("target %d°", round(last$steam_target)),
        swatch = COL$steam
      ),
      div(
        class = "pair",
        tile(
          "Mode",
          if (last$mode == "C") "Coffee" else "Steam",
          paste("switch", cfg$temp_setting)
        ),
        tile("Heater", if (last$heat == 1) "ON" else "off")
      )
    )
  })

  output$temp_plot <- renderPlot(
    {
      invalidateLater(2000)
      df <- recent_readings(win())
      if (nrow(df) < 2) {
        return(empty_plot("Waiting for data…"))
      }
      draw_temps(df, c(Sys.time() - win() * 60, Sys.time()))
    },
    res = 96,
    bg = COL$bg
  )

  output$duty_plot <- renderPlot(
    {
      invalidateLater(2000)
      df <- recent_readings(win())
      if (nrow(df) < 2) {
        return(empty_plot(""))
      }
      draw_duty(df, c(Sys.time() - win() * 60, Sys.time()))
    },
    res = 96,
    bg = COL$bg
  )
}

shinyApp(ui, server)
