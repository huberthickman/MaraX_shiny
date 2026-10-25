# MaraX live dashboard ---------------------------------------------------------
# Single R process: reads the Gicar serial stream, keeps a rolling in-memory
# window (no database), draws live charts, and plays a sound when the machine
# is ready.
#
# Run (from the repository root):
#   Rscript -e 'shiny::runApp("marax_shiny_app", port = 3838)'
# Test without the machine: set `simulate: true` in marax.yml. With `sim_file`
# set, the simulator replays a captured serial log; otherwise it generates a
# synthetic warm-up. See README.md for setup.

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

# Logging ---------------------------------------------------------------------
# Key events always go to the R console (in the browser demo: the browser's
# JavaScript console). With `debug: true` there is also a heartbeat every 10 s.
DEBUG <- isTRUE(cfg$debug %||% TRUE)
log_msg <- function(...) {
  message(format(Sys.time(), "%H:%M:%S"), " [marax] ", ...)
}
log_last <- new.env()
dbg_every <- function(key, secs, ...) {
  # debug message, at most every `secs`
  if (!DEBUG) {
    return(invisible())
  }
  last <- log_last[[key]]
  if (is.null(last) || difftime(Sys.time(), last, units = "secs") >= secs) {
    log_last[[key]] <- Sys.time()
    log_msg(...)
  }
}
log_msg(
  "config: ",
  normalizePath(cfg_path, mustWork = FALSE),
  " | working dir: ",
  getwd(),
  " | ",
  R.version.string
)

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

# Clock -----------------------------------------------------------------------
# Live, this is the wall clock. In the simulator it is a virtual clock running
# sim_speed times faster, so a 45-minute warm-up plays in a few minutes and the
# time-based rules (chart windows, "steady for 3 minutes") speed up with it.
SIMULATE <- isTRUE(cfg$simulate)
SIM_SPEED <- if (SIMULATE) as.numeric(cfg$sim_speed %||% 10) else 1
if (!isTRUE(SIM_SPEED > 0)) {
  stop("sim_speed must be a number greater than 0")
}
clock <- new.env()
clock$origin <- Sys.time() # virtual time at the moment wall0 was taken
clock$wall0 <- Sys.time()

now <- function() {
  if (!SIMULATE) {
    return(Sys.time())
  }
  clock$origin +
    as.numeric(difftime(Sys.time(), clock$wall0, units = "secs")) * SIM_SPEED
}

reset_clock <- function(origin) {
  clock$origin <- origin
  clock$wall0 <- Sys.time()
}

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
store$last_rx <- NULL # wall-clock time data last arrived (for "No data" / off)

# `new`: parsed readings (see parse_lines); `ts`: their times (one, or one each).
add_readings <- function(new, ts) {
  if (is.null(new) || !nrow(new)) {
    return(invisible())
  }
  new <- data.frame(ts = ts, new)
  df <- rbind(store$df, new)
  store$df <- df[df$ts > max(new$ts) - WINDOW_SEC, , drop = FALSE]
  store$last_rx <- Sys.time()
  check_ready(new)
}

clear_readings <- function() {
  store$df <- store$df[0, ]
  store$last_rx <- NULL
}

recent_readings <- function(minutes) {
  df <- store$df
  df[df$ts > now() - minutes * 60, , drop = FALSE]
}

# Parsing -------------------------------------------------------------------
# V1 line: C1.19,116,124,093,0840,1  (mode+fw, steam, steam setpoint, HX, boost, heater)
# The steam setpoint is the controller's command, not a fixed target: in coffee mode
# it drops to keep the heater off and jumps to fire it, to hold the HX temperature.
# The board zero-pads every field (temperatures 3 digits, countdown 4, heater 1),
# so a field of the wrong width means a character was lost on the serial line:
# e.g. "C1.23,10,140,050,0630,1" (steam 107 lost its "7"). Such lines are dropped,
# because the damaged value is often still in range and would plot as a spike.
FIELD_WIDTHS <- c(3, 3, 3, 4, 1)

parse_line <- function(line) {
  f <- trimws(strsplit(trimws(line), ",", fixed = TRUE)[[1]])
  if (length(f) < 6 || !grepl("^[CV][0-9]+\\.[0-9]+$", f[1])) {
    return(NULL)
  }
  if (any(nchar(f[2:6]) != FIELD_WIDTHS) || !all(grepl("^[0-9]+$", f[2:6]))) {
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

# Parse several lines at once. Returns the valid readings as a data frame, plus
# `ok`, which of the input lines they came from; NULL if none were valid.
parse_lines <- function(lines) {
  rows <- lapply(lines, parse_line)
  ok <- !vapply(rows, is.null, logical(1))
  if (!any(ok)) {
    return(NULL)
  }
  rows <- rows[ok]
  cols <- c("mode", "steam", "steam_target", "hx", "boost", "heat")
  df <- as.data.frame(
    lapply(setNames(cols, cols), function(k) unlist(lapply(rows, `[[`, k))),
    stringsAsFactors = FALSE
  )
  list(rows = df, ok = ok)
}

# Ready alert -----------------------------------------------------------------
alert <- new.env()
alert$state <- "off" # off -> warming -> ready
alert$ready_at <- NULL

# cfg$sound: a beepr sound number or name (3 = "fanfare"), a path to a .wav,
# or false to stay quiet.
play_alert <- function() {
  message(
    "MaraX ready at ",
    format(now(), "%H:%M:%S"),
    if (SIMULATE) " (simulator time)" else ""
  )
  snd <- cfg$sound %||% 3
  if (isFALSE(snd)) {
    return(invisible())
  }
  tryCatch(
    beepr::beep(snd),
    error = function(e) message("Sound failed: ", conditionMessage(e)),
    warning = function(w) message("Sound warning: ", conditionMessage(w))
  )
}

# `new`: the readings just added (a batch can hold several lines).
check_ready <- function(new) {
  df <- store$df
  last <- df[nrow(df), ]
  if (alert$state == "off") {
    alert$state <- "warming"
    alert$saw_cold <- FALSE
  }
  if (alert$state != "warming") {
    return(invisible())
  }
  # Only sound the alert if we actually watched a warm-up (not when the app
  # restarts while the machine is already hot).
  if (any(new$boost > 0 | new$hx < READY_HX - 5)) {
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

# Background loop control ---------------------------------------------------------
# The serial / replay / synthetic loops reschedule themselves with `later`.
# Two things must stop them:
#  - The app stopping. In an interactive R session (Positron, RStudio) `later`
#    keeps running callbacks at the console prompt, so without this the loop
#    would carry on after the app has stopped.
#  - A newer copy of the app starting in the same R session, e.g. autoreload
#    re-running app.R after an edit. The newest copy owns the loop; older
#    copies notice at their next tick and stop.
LOOP_ID <- paste(
  Sys.getpid(),
  format(Sys.time(), "%H%M%OS6"),
  sample.int(1e6, 1),
  sep = "-"
)
options(marax.loop_id = LOOP_ID)

loop_alive <- function() identical(getOption("marax.loop_id"), LOOP_ID)

schedule <- function(fun, delay) {
  if (loop_alive()) {
    return(invisible(later::later(fun, delay)))
  }
  close_serial() # release the port for whoever runs next
  log_msg("background loop stopped")
  invisible()
}

shiny::onStop(function() {
  if (loop_alive()) {
    options(marax.loop_id = NULL)
  }
  log_msg("app stopped")
})

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

# Returns how long to wait before the next poll.
serial_step <- function() {
  if (!is.null(ser$con) && !port_present(ser$port)) {
    log_msg("serial: ", ser$port, " disappeared (unplugged?)")
    close_serial()
  }
  if (is.null(ser$con)) {
    if (!open_serial()) {
      dbg_every("serial-wait", 60, "serial: waiting for port ", ser$port)
      watchdog()
      return(5) # retry
    }
    log_msg("serial: opened ", ser$port)
  }
  lines <- tryCatch(read_serial_lines(), error = function(e) {
    log_msg("serial: read failed (", conditionMessage(e), "); reopening")
    close_serial()
    character()
  })
  if (length(lines)) {
    add_readings(parse_lines(lines)$rows, Sys.time())
  }
  dbg_every(
    "serial",
    10,
    "serial: ",
    length(lines),
    " lines this poll | buffer ",
    nrow(store$df),
    " rows | status ",
    alert$state
  )
  watchdog()
  0.25
}

poll_serial <- function() {
  delay <- tryCatch(serial_step(), error = function(e) {
    log_msg("serial ERROR: ", conditionMessage(e))
    5
  })
  schedule(poll_serial, delay)
}

# Simulator: replay a capture (simulate: true, sim_file set) -------------------
# A capture has one serial reading per line: an ISO timestamp, a tab, then the
# raw line, e.g. "2026-10-17T07:04:33.878<TAB>C1.23,020,000,020,0000,0".
# The replay keeps the original spacing between lines (divided by sim_speed),
# and the charts show the original clock times.
read_capture <- function(path) {
  log_msg("replay: opening ", normalizePath(path, mustWork = FALSE))
  x <- sub("\r$", "", readLines(path, warn = FALSE))
  log_msg(
    "replay: read ",
    length(x),
    " lines; first: ",
    if (length(x)) encodeString(x[1]) else "(none)"
  )
  parts <- strsplit(x, "\t", fixed = TRUE)
  parts <- parts[lengths(parts) >= 2]
  ts <- as.POSIXct(vapply(parts, `[`, "", 1), format = "%Y-%m-%dT%H:%M:%OS")
  raw <- vapply(parts, `[`, "", 2)
  keep <- !is.na(ts)
  log_msg(
    "replay: ",
    length(parts),
    " lines have a tab; ",
    sum(keep),
    " have a readable timestamp"
  )
  ts <- ts[keep]
  raw <- raw[keep]
  if (length(ts) < 2) {
    stop("No readable lines in sim_file '", path, "'")
  }
  o <- order(ts)
  cap <- list(
    start = ts[o][1],
    off = as.numeric(difftime(ts[o], ts[o][1], units = "secs")),
    raw = raw[o]
  )
  log_msg(sprintf(
    "replay: %s to %s (%.1f min); plays in %.1f min at x%g",
    format(cap$start, "%Y-%m-%d %H:%M:%S"),
    format(ts[o][length(o)], "%H:%M:%S"),
    max(cap$off) / 60,
    max(cap$off) / 60 / SIM_SPEED,
    SIM_SPEED
  ))
  cap
}

replay <- new.env()

start_replay <- function() {
  clear_readings()
  alert$state <- "off" # behave like a fresh power-on
  alert$ready_at <- NULL
  reset_clock(replay$cap$start)
  replay$i <- 1L # next line to play
}

replay_step <- function() {
  cap <- replay$cap
  n <- length(cap$off)
  elapsed <- as.numeric(difftime(now(), cap$start, units = "secs"))
  if (replay$i <= n) {
    k <- findInterval(elapsed, cap$off) # last line that is due
    if (k >= replay$i) {
      idx <- replay$i:k
      p <- parse_lines(cap$raw[idx])
      if (!is.null(p)) {
        add_readings(p$rows, cap$start + cap$off[idx][p$ok])
      }
      if (replay$i == 1L) {
        log_msg(
          "replay: first readings added (lines 1-",
          k,
          ", ",
          if (is.null(p)) 0 else nrow(p$rows),
          " valid); buffer has ",
          nrow(store$df),
          " rows"
        )
      }
      replay$i <- k + 1L
    }
    dbg_every(
      "replay",
      10,
      "replay: line ",
      replay$i - 1L,
      "/",
      n,
      " | simulator time ",
      format(now(), "%H:%M:%S"),
      " | buffer ",
      nrow(store$df),
      " rows",
      if (nrow(store$df)) {
        paste0(", newest ", format(max(store$df$ts), "%H:%M:%S"))
      } else {
        ""
      },
      " | status ",
      alert$state
    )
  } else if (isTRUE(cfg$sim_loop %||% TRUE) && elapsed > cap$off[n] + 5) {
    log_msg("replay: reached the end; starting again")
    start_replay() # loop: play it again from the start
  }
  watchdog()
}

# Errors are logged and the loop keeps going; otherwise one error would stop
# the replay silently and leave the dashboard on "Waiting for data".
poll_replay <- function() {
  tryCatch(replay_step(), error = function(e) {
    log_msg("replay ERROR: ", conditionMessage(e))
  })
  schedule(poll_replay, 0.25)
}

# Simulator: synthetic warm-up (simulate: true, no sim_file) -----------------
sim <- new.env()

# One synthetic line for `t` seconds (simulator time) after power-on.
sim_line <- function(t) {
  target <- 124
  base <- target - (target - 22) * exp(-t / 240)
  osc <- 1.5 * sin(t / 40) * (1 - exp(-t / 240))
  heat <- as.integer(base < target - 3 || cos(t / 40) > 0)
  hx_end <- READY_HX + 2
  hx <- hx_end - (hx_end - 22) * exp(-t / 420)
  ph <- t %% 600
  # A simulated "shot" every 10 min, starting after the machine has gone ready.
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

# Emit a line every 0.5 s of simulator time, like the real machine.
sim_step <- function() {
  t_now <- as.numeric(difftime(now(), sim$t0, units = "secs"))
  if (sim$next_t <= t_now) {
    first <- sim$next_t == 0
    t <- seq(sim$next_t, t_now, by = 0.5)
    p <- parse_lines(vapply(t, sim_line, ""))
    if (!is.null(p)) {
      add_readings(p$rows, sim$t0 + t[p$ok])
    }
    sim$next_t <- max(t) + 0.5
    if (first) {
      log_msg(
        "synthetic: first readings added; buffer has ",
        nrow(store$df),
        " rows"
      )
    }
  }
  dbg_every(
    "sim",
    10,
    "synthetic: simulator time ",
    format(now(), "%H:%M:%S"),
    " | buffer ",
    nrow(store$df),
    " rows | status ",
    alert$state
  )
}

poll_sim <- function() {
  tryCatch(sim_step(), error = function(e) {
    log_msg("synthetic ERROR: ", conditionMessage(e))
  })
  schedule(poll_sim, 0.25)
}

# Start -----------------------------------------------------------------------
SIM_FILE <- if (SIMULATE && length(cfg$sim_file) && nzchar(cfg$sim_file)) {
  cfg$sim_file
} else {
  NULL
}
SIM_LABEL <- NULL
MODE <- if (!SIMULATE) {
  "live serial"
} else if (!is.null(SIM_FILE) && file.exists(SIM_FILE)) {
  "replay"
} else {
  "synthetic"
}

if (!SIMULATE) {
  log_msg(
    "mode: live serial (port setting: ",
    PORT_CFG,
    "); set simulate: true to use the simulator"
  )
  poll_serial()
} else if (!is.null(SIM_FILE) && file.exists(SIM_FILE)) {
  log_msg(
    "mode: replay of '",
    SIM_FILE,
    "' at x",
    SIM_SPEED,
    if (isTRUE(cfg$sim_loop %||% TRUE)) ", looping" else ", once"
  )
  replay$cap <- read_capture(SIM_FILE)
  SIM_LABEL <- sprintf(
    "Replay of %s · ×%g",
    format(replay$cap$start, "%d %b %H:%M"),
    SIM_SPEED
  )
  start_replay()
  poll_replay()
} else {
  if (!is.null(SIM_FILE)) {
    log_msg(
      "sim_file '",
      SIM_FILE,
      "' not found in ",
      getwd(),
      "; using the synthetic warm-up"
    )
  }
  log_msg("mode: synthetic warm-up at x", SIM_SPEED)
  SIM_LABEL <- sprintf("Simulated · ×%g", SIM_SPEED)
  sim$t0 <- now()
  sim$next_t <- 0
  poll_sim()
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

  st <- gapped(df$ts, df$steam_target) # heater setpoint (dashed)
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
  padding:4px 10px; }
/* Pin every button state to the dark theme. Bootstrap's own hover/focus/pressed
   styles use a light background, which stays after a tap (focus, and sticky
   hover on touchscreens) and hid the light label text. */
.toolbar .btn, .toolbar .btn:hover, .toolbar .btn:focus, .toolbar .btn:active,
.toolbar .btn:active:hover, .toolbar .btn:active:focus, .toolbar .btn:focus:hover {
  background:%3$s !important; color:%2$s !important; border:1px solid #3a3a37 !important;
  box-shadow:none !important; outline:none; }
.toolbar .btn.active, .toolbar .btn.active:hover, .toolbar .btn.active:focus,
.toolbar .btn.active:active {
  background:#3a3a37 !important; border-color:%4$s !important; }
/* Keyboard users still get a visible focus ring; mouse and touch don't. */
.toolbar .btn:focus-visible { outline:2px solid %4$s; outline-offset:2px; }
/* Hover feedback only where a real pointer exists (not on touchscreens). */
@media (hover: hover) {
  .toolbar .btn:not(.active):hover { background:#2c2c2a !important; } }
.toolbar .sim { font-size:clamp(12px, 1.8vh, 14px); color:%4$s; border:1px solid #3a3a37;
  border-radius:8px; padding:4px 10px; white-space:nowrap; }
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

# Browser tab icon: a ☕ emoji drawn as an inline SVG, so no image file is needed.
# The shinylive build adds the same icon through its export template (see
# .github/workflows/deploy-shinylive.yml), since there the tab belongs to the
# outer page.
FAVICON <- "data:image/svg+xml,%3Csvg%20xmlns=%27http://www.w3.org/2000/svg%27%20viewBox=%270%200%20100%20100%27%3E%3Ctext%20y=%27.9em%27%20font-size=%2790%27%3E%E2%98%95%3C/text%3E%3C/svg%3E"

ui <- tagList(
  tags$head(
    tags$style(HTML(css)),
    tags$title("MaraX Dashboard"),
    tags$link(rel = "icon", href = FAVICON),
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
        span(
          class = "title",
          "Temperatures (°C) — dashed = heater setpoint, shaded = heater on"
        ),
        if (!is.null(SIM_LABEL)) span(class = "sim", SIM_LABEL),
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
        tile("Status", "No data", if (SIMULATE) "simulator" else ser$port),
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
        sprintf("setpoint %d°", round(last$steam_target)),
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
        all <- store$df
        dbg_every(
          "chart",
          10,
          "chart (",
          MODE,
          " mode): ",
          nrow(df),
          " readings in the last ",
          win(),
          " min | buffer ",
          nrow(all),
          " rows",
          if (nrow(all)) {
            paste0(
              " (",
              format(min(all$ts), "%H:%M:%S"),
              " to ",
              format(max(all$ts), "%H:%M:%S"),
              ")"
            )
          } else {
            ""
          },
          " | clock now ",
          format(now(), "%Y-%m-%d %H:%M:%S")
        )
        return(empty_plot("Waiting for data…"))
      }
      t_end <- now()
      draw_temps(df, c(t_end - win() * 60, t_end))
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
      t_end <- now()
      draw_duty(df, c(t_end - win() * 60, t_end))
    },
    res = 96,
    bg = COL$bg
  )
}

shinyApp(ui, server)
