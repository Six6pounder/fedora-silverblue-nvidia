# Initialize zoxide (smarter cd) for interactive bash shells.
# Provides the `z` command system-wide.
case $- in
    *i*) eval "$(zoxide init bash)" ;;
esac
