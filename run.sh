#!/bin/sh

# This is just a wrapper to run pacsub-manage from within this repository.
# It just appends this directory to the perl include path.

HERE="$0"
HERE="${HERE%/*}"

exec perl -I"$HERE" "${HERE}/pacsub-manage" "$@"
