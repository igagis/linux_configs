#!/bin/bash

# NOTE: to close calendar on focus lost (click outside) do the following config:
#
#	$ mkdir -p ~/.config/gsimplecal
#       $ echo 'close_on_unfocus = 1' >> ~/.config/gsimplecal/config
#

date '+%Y-%m-%d %H:%M:%S'

if [ "$BLOCK_BUTTON" == "1" ]; then
	gsimplecal
fi
