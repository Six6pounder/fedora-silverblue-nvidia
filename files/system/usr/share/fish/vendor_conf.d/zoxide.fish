# Initialize zoxide (smarter cd) for all interactive fish shells.
# Provides the `z` command; placed in vendor_conf.d so it's system-wide.
if status is-interactive
    zoxide init fish | source
end
