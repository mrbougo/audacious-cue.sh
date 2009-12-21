#!/bin/bash

refresh=2  # refresh interval in watch mode

#player settings
pname=audacious
ST_stop=stopped
ST_play=playing
ST_pause=paused

err() {
	echo "$*" >&2
}

err_run() {
	err "$pname is not running."
	loaded=0
}

printhelp() {
cat << EOF
$pname cue sheet control script.

Commands:
	h, ?		Print this help
	q		quit
	l		List the tracks
	i		Identify the current track in context
	I		Identify the current track
	w		Watch the current track in context
	W		Watch the current track
	s<n>		Skip to track <n>
	r		Reload the sheet
EOF
}

awkscript() {
cat << 'EOF'
	function getval(i,     s, spc) {
		#spc avoids spaces as first chars, substr is broken with special chars
		spc = "";
		for (i; i<=NF; i++)
		{
			s = s spc $i;
			spc = " ";
		}
		gsub(/\r/, "", s);
		gsub(/^.|.$/, "\"", s); #the first and last should _always_ be quotes, but let's be safe and quote the whole thing
		gsub(/'/, "'\\''", s); #one single backslash gives a warning: awk will treat it as "'"
		gsub(/^.|.$/, "'", s); #doing this without the first similar replacement would still allow for eval code injection abusing the 2nd replacement
		return s
	}

	$1 == "TRACK" {
		track = $2 + 0;
	}

	$1 == "PERFORMER" {
		performer[track] = getval(2);
	}

	$1 == "TITLE" {
		title[track] = getval(2);
	}

	#audtool uses integer seconds (the manpage is a lie)
	#using milliseconds to compare with the current position
	$1 == "INDEX" {
		split($3, idx, ":");
		frames[track] = (60 * idx[1] + idx[2]) * 1000;
	}

	END {
		spc = "";
		for (i=1; i<=track; i++)
		{
			ap = ap spc performer[i];
			at = at spc title[i];
			af = af spc frames[i];
			spc = " ";
		}
		print "performer=(" ap ")"
		print "title=(" at ")"
		print "frames=(" af ")"
		print "tracks=" track
	}

EOF
}

chkrun() {
	killall -0 -- "$pname" > /dev/null
}

### Player communication ###

play() {
	audtool --playback-play
}

pause() {
	audtool --playback-pause
}

getfn() {
	local audf
	audf=$(audtool  --current-song-filename)
	if [[ -z $audf ]]; then
		err "No file opened."
		return 2
	elif [[ ! -f $audf ]]; then
		err "Not a local file."
		return 3
	fi
	echo "$audf"
	return 0
}

gett() {
	audtool --current-song-output-length-frames  #milliseconds
}

getstatus() {
	audtool --playback-status
}

sett() {
	#seconds, not milliseconds
	audtool  --playback-seek $(($1/1000))
}

### Cue/data array manipulation ###

getcue() {
	local dir=$(dirname "$1")
	# If no cue sheet is found, it fails thanks to /dev/null which never matches
	shopt -s nullglob
	for f in "$dir"/*.cue /dev/null; do
		grep -F -- "${1##*/}" "$f" > /dev/null && break
	done || { err "No cue sheet found"; return 1; }
	echo "$f"
}

parsecue() {
	eval $(awk "$(awkscript)" "$1")
}

load() {
	local cuefile
	chkrun || { err_run; return 1; }
	loaded=0
	if [[ -n "$1" ]]; then
		fn="$1"
	else
		fn="$(getfn)" || return 1
	fi
	cuefile="$(getcue "$fn")" && parsecue "$cuefile" && loaded=1
}

check() {
	local fnnew
	fnnew="$(getfn)"
	[[ "$fn" != "$fnnew" ]] && load "$fnnew" > /dev/null
	if [[ $loaded == 0 || $tracks == 0 ]]; then
		err "Could not load a cue sheet. Use r to reload."
		return 1
	else
		return 0
	fi
}

getnum() {
	local i
	local time=$(gett)
	for ((i=0; i<tracks; i++)); do
		[[ ${frames[$i]} -gt $time ]] && break
	done
	echo $((i-1))
}

### Commands ###

getid() {
	[[ "$1" == "f" ]] || chkrun || { err_run; return 1; }
	check || return 1
	local num=$(getnum)
	echo $((num+1)). ${performer[$num]} - ${title[$num]}
}

skip() {
	chkrun || { err_run; return 1; }
	check || return 1
	if [[ $1 -gt $tracks || $1 -le 0 ]]; then
		err "Wrong track number. Correct range: 1-$tracks."
	else
		[[ "$(getstatus)" == "$ST_stop" ]] && { play && pause || return 1; }
		sett ${frames[$(($1-1))]}
	fi
}

list() {
	[[ "$2" == "f" ]] || chkrun || { err_run; return 1; }
	check || return 1
	local i num
	[[ "$1" == "2" ]] && num=$(getnum)
	for ((i=0; i<tracks; i++)); do
		[[ $i == $num ]] && echo -n ">>>"
		echo $((i+1)). ${performer[$i]} - ${title[$i]}
	done
}

watch() {
	local l buffer1 oldbuffer
	chkrun || { err_run; return 1; }
	[[ $1 == 1 ]] && l="list 2 f" || l="getid f"
	buffer="$($l)" && oldbuffer="$buffer" || return 1
	clear; echo "$buffer"
	until read -n1 -t$refresh -s; do
		chkrun || return 1
		[[ "$(getstatus)" != "$ST_stop" ]] || { echo "Playback stopped."; break; }
		oldbuffer="$buffer"; buffer="$($l)" || return 1
		[[ "$oldbuffer" != "$buffer" ]] && { clear; echo "$buffer"; }
	done
}

loaded=0

if [[ $# -gt 0 ]]; then
	err "Arguments are not supported yet."
	exit 1
fi

load

#wW call lL or i
#needcheck='[iIlLrRsS]'
while read -n1 -p ':' cmd; do
	# negating the return of chkrun to simplify the expression
	#[[ "$cmd" =~ $needcheck ]] && ! chkrun && { err_run; continue; }
	[[ "$cmd" == "s" || "$cmd" == "S" ]] || echo
	case $cmd in
		h|H|\?) printhelp;;
		i)     list 2;;
		I)     getid;;
		l|L)   list 1;;
		q|Q)   exit 0;;
		r|R)   load; [[ $loaded == 1 ]] && echo "Cue sheet reloaded." || echo "Cue sheet reloading failed.";;
		s|S)   read sel && skip sel;;
		w)     watch 1;;
		W)     watch 2;;
		*)     err 'h for help'
	esac
done
