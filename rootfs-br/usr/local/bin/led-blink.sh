#!/bin/sh
# Blue status LED on Milk-V Duo (GPIO 440, active-low).
set -eu

LED_PIN=440
GPIO="/sys/class/gpio/gpio${LED_PIN}"
PIDFILE="/var/run/led-blink.pid"

export_gpio() {
  if [ ! -d "$GPIO" ]; then
    echo "$LED_PIN" > /sys/class/gpio/export 2>/dev/null || true
  fi
  echo out > "$GPIO/direction" 2>/dev/null || true
}

led_on() {
  export_gpio
  echo 0 > "$GPIO/value"
}

led_off() {
  export_gpio
  echo 1 > "$GPIO/value"
}

stop_blink() {
  if [ -f "$PIDFILE" ]; then
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  led_off
}

start_blink() {
  stop_blink
  export_gpio
  (
    while true; do
      echo 0 > "$GPIO/value"
      sleep 0.12
      echo 1 > "$GPIO/value"
      sleep 0.12
    done
  ) &
  echo $! > "$PIDFILE"
}

case "${1:-}" in
  start)  start_blink ;;
  stop)   stop_blink ;;
  off)    stop_blink ;;
  on)     stop_blink; led_on ;;
  status)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo blinking
    else
      echo off
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|off|on|status}" >&2
    exit 1
    ;;
esac
