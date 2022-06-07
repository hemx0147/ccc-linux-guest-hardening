#!/bin/bash

# Quick summary of findings
#
# Scan all logs for some crash/issue identifier, e.g. "RIP:" or KASAN: string.
# Then reverse-sort to get a mapping of unique identifiers to logs per harness
# Also report any crash logs that could not be associated to a crash identifier

dir=$(realpath $1)

LOGS_CRASH="logs_crash.lst"
LOGS_KASAN="logs_kasan.lst"
LOGS_TIMEO="logs_timeo.lst"

# which logs to scan? timeout logs can be crappy
SCAN_LOGS="$LOGS_KASAN $LOGS_CRASH"
SCAN_LOGS="$LOGS_KASAN $LOGS_CRASH $LOGS_TIMEO"

# order of bug classes to print (will only print these!)
CLASSES_ORDER="KASAN CRASH WARNS HANGS"

# identify panic handler reason based on build config :-/
PANIC_STRING='SMP KASAN NOPTI$'

DECODE_STACKTRACE=$LINUX_GUEST/scripts/decode_stacktrace.sh

# files to decode
DECODE_LIST=stack_decode.lst
REPRO_LIST=reproducer.lst

if ! cd $dir; then
	echo "Could not enter $dir - exit."
	exit
fi

if ! test -x $SCRIPT; then
	echo "Could not find $SCRIPT - exit."
	exit
fi

test -f $DECODE_LIST && rm $DECODE_LIST
test -f $REPRO_LIST && rm $REPRO_LIST

find */logs -name crash_\*log > $LOGS_CRASH
find */logs -name kasan_\*log > $LOGS_KASAN
find */logs -name timeo_\*log > $LOGS_TIMEO

declare -A tag2msg
declare -A tag2log
declare -A class2tag
declare -A log2note
declare -A unique_logs

register_issue() {
	msg=$1
	log=$2
	class=$3
	TAGLEN=5

	if test -n "$msg"; then
		msg=$(echo "$msg"|grep -v '^ \? \|^Call Trace:\|^CPU:\|^Code:\|^CR2:\|^CS:\|^FS:\|^R13:\|^R10:\|^RBP:\|^RDX:\|^RSP:')
		# shorten output strings and remove detailed line offsets and address details
		msg=$(echo "$msg"|sed -e 's/general protection fault/#GP/' -e 's/+0x[0-9,a-f,x,/]*//g' -e 's/RIP: 0010:/RIP: /')
		msg=$(echo "$msg"|sed -e 's/stuck for [0-9]*s.*/stuck for [s] secs/' -e 's/for address 0x[0-9,a-f]*:/for address [n]:/')
		msg=$(echo "$msg"|sed -e 's/in range \[0x[0-9,a-f]*-0x[0-9,a-f]*\]/in range [x-y]/')
		msg=$(echo "$msg"|sed -e 's/of size [0-9]* at addr/of size N at addr/')
		msg=$(echo "$msg"|tr '\n' ' ')
		tag=$(echo "$msg,$class"|cksum -|cut -b -$TAGLEN)

		if ! echo "$CLASSES_ORDER"|grep -q $class; then
			echo "Warning: error class $class will not be printed."
		fi

		if test -z "${tag2msg[$tag]}"; then
			tag2msg[$tag]="$msg"
			tag2log[$tag]="$log"

			if test -z "${class2tag[$class]}"; then
				class2tag[$class]="$tag"
			else
				class2tag[$class]="${class2tag[$class]} $tag"
			fi
		else
			tag2log[$tag]="${tag2log[$tag]},$log"
		fi

		# backward-search log for some interesting messages to help spot different executions
		NOTE=$(tac $log|grep -i -m 1 "error\|fatal\|warn\|fail")
		[ -n "$NOTE" ] && NOTE=$(echo "<i>last error:</i> $NOTE"|sed 's/+0x[0-9,a-f,x,/]*//g')
		log2note[$log]="$NOTE"

		#echo -e "$tag;$msg;$log"
		return 0
	else
		return 1
	fi
}

get_workdir_from_logname() {
	log=$1
	# logs are in parent
	DIR1="$(realpath --relative-to $dir "$(dirname $log)/..")"
	if test -f "$DIR1/stats"; then
		echo "$DIR1"
	else
		# triage logs are in parent^2
		DIR1="$(realpath --relative-to $dir "$(dirname $log)/../..")"
		echo "$DIR1"
	fi
}

get_harness_from_logname() {
	# harness is encoded in first part of workdir folder name
	log=$1
	basename $(get_workdir_from_logname $log)|sed 's/-.*//'
}

get_hash_from_logname() {
	basename $log|sed -e 's/.*_//' -e 's/.log.*//'
}

get_unique_candidates() {
	# populate unique_logs[] based on tag, harness and log excerpt
	# for each interesting candidate, also try to find the corresponding payload based on bitmap hash
	for class in $CLASSES_ORDER; do
		for tag in ${class2tag[$class]}; do
			logs="$(echo "${tag2log[$tag]}"|sed 's/,/\n/g')"
			for log in $logs; do
				harness=$(get_harness_from_logname $log)
				logid=$(echo "$tag,$class,$harness,${log2note[$log]}"|cksum -|cut -b -8)
				if test -z "${unique_logs[$logid]}"; then
					unique_logs[$logid]="$log"
				else
					unique_logs[$logid]="${unique_logs[$logid]},$log"
				fi
			done
		done
	done
}

decode_log() {
	log=$1

	if ! test -f $log; then
		echo "Error: attempt to decode invalid file $log. Exit" >&2
	fi

	# get vmlinux image for from $workdir/target/
	ELF="$(get_workdir_from_logname $log)/target/vmlinux"

	# decode using Linux helper script in $LINUX_GUEST
	if ! test -f $ELF; then
		echo "Warning: Could not find ELF image for $ELF - skipping decode..." >&2
	else
		if test -f "$log.txt"; then
			echo "$log.txt exists, skip decoding.." >&2
			echo "$log.txt"
		else
			echo "$DECODE_STACKTRACE $ELF < $log ..." >&2
			$DECODE_STACKTRACE $ELF < "$log" > "$log.txt"
			echo "$log"
		fi
	fi
}

decode_unique_logs() {
	MAX_SAMPLES=2
	for logs in ${unique_logs[*]}; do
		for log in $(echo "$logs"|tr ',' '\n'|head -$MAX_SAMPLES); do
			decoded=$(decode_log $log)
		done
	done
}

for log in $(cat $SCAN_LOGS); do
	# explicit (outline?) KASAN results reported by bug() handler
	msg=$(grep -A 1 '^BUG: KASAN:' $log|sed 's/^BUG: //')
	register_issue "$msg" "$log" "KASAN" && continue

	## catch KASAN reported as part of general #GP crash handler (CONFIG_KASAN_INLINE)
	msg=$(grep -A 3 '^KASAN:' $log|grep '^RIP:\|^KASAN:')
	register_issue "$msg" "$log" "KASAN" && continue

	## catch common panic() handler, where RIP is shown shortly after error type + build flags "SMP KASAN NOPTI" string
	# some of these may contain an additional KASAN: line but we probably cought those in previous rule..
	msg=$(grep -v '^CPU:\|^Modules linked in:' $log|grep -m 2 -A 3 'KASAN NOPTI$'|grep '^RIP:\|^KASAN:\|KASAN NOPTI$'|sed s/'SMP KASAN NOPTI'//)
	register_issue "$msg" "$log" "CRASH" && continue

	## catch unchecked MSR access
	msg=$(grep -m 1 '^unchecked MSR access error:' $log)
	register_issue "$msg" "$log" "WARNS" && continue

	## catch WARNING: and BUG:, - look at first two RIPs in case there is some useful output in between
	msg=$(grep -v '^CPU:\|^Modules linked in:' $log|grep -m 2 '^WARNING:\|^BUG:'|sed s/'SMP KASAN NOPTI'//)
	msg=$(echo "$msg"|grep -v '^ ? \|^Call Trace:\|^Code:\|^CR2:\|^CS:\|^FS:\|^R13:\|^R10:\|^RBP:\|^RDX:\|^RSP:')
	register_issue "$msg" "$log" "WARNS" && continue

	## fallback: look 2-3 lines backward from RIP extract any other issues
	# look at first 2 RIP matches and remove CPU/stack info
	#msg=$(grep -v '^ ? \|^Call Trace:' $log|grep -m 1 -B 2 ^RIP:|sed s/\(.*//)
	msg=$(grep -v '^CPU:\|^Modules linked in:' $log| grep -m 2 -B 1 ^RIP:|sed s/\(.*//)
	msg=$(echo "$msg"|grep -v '^ ? \|^Call Trace:\|^Code:\|^CR2:\|^CS:\|^FS:\|^R13:\|^R10:\|^RBP:\|^RDX:\|^RSP:')
	register_issue "$msg" "$log" "WARNS" && continue

	if grep -q $log $LOGS_TIMEO; then
		register_issue "Unclassified HANGS" "$log" "HANGS"
	else
		register_issue "Unclassified CRASH" "$log" "WARNS"
	fi
done

SCAN_LOGS_NUM=$(cat $SCAN_LOGS|wc -l)
rm $LOGS_CRASH
rm $LOGS_KASAN
rm $LOGS_TIMEO

get_unique_candidates
decode_unique_logs

for tag in ${!tag2msg[*]}; do
	echo -e "$tag;${tag2msg[$tag]};${tag2log[$tag]};"
done > summary.csv

(
	echo "Scanned logs: $SCAN_LOGS ($SCAN_LOGS_NUM logs total)"
	echo "Identified ${#tag2msg[*]} issues:"
	for class in $CLASSES_ORDER; do
		[ -n "${class2tag[$class]}" ] && echo -e "\t$class: ${class2tag[$class]}"
	done
	echo
	for class in $CLASSES_ORDER; do
		for tag in ${class2tag[$class]}; do
			logs="$(echo "${tag2log[$tag]}"|sed 's/,/,\n\t/g')"
			echo -e "[$tag] ${tag2msg[$tag]}\n\t$logs\n"
		done
	done
) > summary.txt

get_best_stackdump() {
	log=$1

	cksum=$(get_hash_from_logname $log)
	workdir=$(get_workdir_from_logname $log)

	# full match not handled - not ever finding these..
	test -f "$workdir/triage/repro_*_${cksum}_${cksum}\*" && echo ">>>exact reproducer at $workdir/triage/repro_*_${cksum}_${cksum}<<<"

	# consider same exit code as good match
	stacklog="$(find $workdir/triage/repro_*_${cksum}_*\+ -name stacks.log 2>/dev/null |head -1)"
	if test -n "$stacklog" -a -f "$stacklog"; then
		if test -f $stacklog.txt; then
			echo $stacklog.txt
		else
			# do not decode stacks.log inline since they can be quite big
			echo "$stacklog" >> $DECODE_LIST
			#decode_log "$stacklog" # returns the generated output file
			echo $stacklog
		fi
	else
		# log missing reproducers
		echo "$workdir,$cksum" >> $REPRO_LIST
	fi
}

(
	echo '<pre>'
	echo "Scanned logs: $SCAN_LOGS ($SCAN_LOGS_NUM logs total)"
	echo "Identified ${#tag2msg[*]} issues:"
	for class in $CLASSES_ORDER; do
		[ -z "${class2tag[$class]}" ] && continue
		num_issues=$(echo ${class2tag[$class]}|wc -w)
		printf "\t%8s: ${class2tag[$class]}\n" "$num_issues $class"
	done
	echo "<p>"
	for class in $CLASSES_ORDER; do
		[ -z "${class2tag[$class]}" ] && continue
		case $class in
			"KASAN"|"CRASH")
				echo "<details open>"
				;;
			*)
				echo "<details>"
				;;
		esac
		num_issues=$(echo ${class2tag[$class]}|wc -w)
		echo "<summary><b>Category $class ($num_issues items)</b></summary>"
		for tag in ${class2tag[$class]}; do
			echo -e "<table><tr><th colspan=3 align=left>[$tag] ${tag2msg[$tag]}</th></tr>\n"
			logs="$(echo "${tag2log[$tag]}"|sed 's/,/\n/g')"
			for log in $logs; do
				# some logs have additional triage/debug info stored alongside
				HARNESS="$(get_harness_from_logname $log)"
				LOGREF="<a href=\"$log\">$(basename $log)</a>"
				CALLS=""
				DECODED=""
				if [ -f ${log}.txt ]; then
					DECODED="<a href=\"$log.txt\">[decoded]</a>" || DECODED=""
					CALLS="$(get_best_stackdump $log)"
					if test -n "$CALLS" -a -f "$CALLS"; then
						CALLS="<a href=\"$CALLS\">[input log]</a>"
					else
						CALLS=""
					fi
				#trace=$(get_best_traceprint $log) # not useful at this point
				#test -n "$trace" && echo -e "\t  <a href=\"$trace\">[trace log]</a>"
				fi
				printf "<tr><td style=\"padding-left:20px\">via $HARNESS harness:</td><td>%s</td><td>${log2note[$log]}</td></tr>\n" "$LOGREF $DECODED $CALLS"
			done
			echo "</table><p />"
		done
		echo "</details>"
	done
	echo '</pre>'
) > summary.html


