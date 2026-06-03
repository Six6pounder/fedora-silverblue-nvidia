# Initialize the Starship prompt for all interactive fish shells.
# Placed in vendor_conf.d so it's sourced system-wide without touching ~/.config.
if status is-interactive
    starship init fish | source
end
