#!/bin/bash

# NOTE: this script needs this utility:
#       https://github.com/nonpop/xkblayout-state

LG=$(xkblayout-state print "%s" | tr -d '\n\r')
IFS=',' read -ra LAYOUT <<< $(setxkbmap -query | awk '/layout/{print $2}')
lastidx=$( expr ${#LAYOUT[@]} - 1 )
#res="{ \"full_text\": \"🖮:\", \"separator\":false, \"separator_block_width\": 6 }"

for index in "${!LAYOUT[@]}"
do
	i="${LAYOUT[index]}"
	if [ $i == $LG ]
	then
		res="$res[$i]"
#		c=", \"color\":\"#FF0000\", \"border\":\"#AAAAAA\""
	else
		res="${res} ${i} "
#		c=", \"color\":\"#444444\""
	fi

	# if [[ $index -ne $lastidx ]]; then
#		e=""

#	else
#		e=", \"separator\":false, \"separator_block_width\": 6 "
	# 	res="$res "
	# fi
#	res="$res,{ \"full_text\": \"$i\"$c$e}"
done

echo "$res"
