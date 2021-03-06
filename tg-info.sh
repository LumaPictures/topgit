#!/bin/sh
# TopGit - A different patch queue manager
# Copyright (C) Petr Baudis <pasky@suse.cz>  2008
# Copyright (C) Kyle J. McKay <mackyle@gmail.com>  2015, 2016, 2017
# GPLv2

USAGE="\
Usage: ${tgname:-tg} [...] info [--heads | --leaves | --series[=<head>]] [<name>]
   Or: ${tgname:-tg} [...] info [--deps | --dependencies | --dependents] [<name>]"

usage()
{
	if [ "${1:-0}" != 0 ]; then
		printf '%s\n' "$USAGE" >&2
	else
		printf '%s\n' "$USAGE"
	fi
	exit ${1:-0}
}

## Parse options

datamode=
heads=
leaves=
deps=
dependents=
series=
serieshead=
verbose=

while [ $# -gt 0 ]; do case "$1" in
	-h|--help)
		usage
		;;
	--heads)
		heads=1 datamode=1
		;;
	--leaves)
		leaves=1 datamode=1
		;;
	--deps|--dependencies)
		deps=1 datamode=1
		;;
	--dependents)
		dependents=1 datamode=1
		;;
	--series)
		series=1 datamode=1
		;;
	--series=*)
		series=1 datamode=1
		serieshead="${1#--series=}"
		;;
	-v|--verbose)
		verbose=$(( ${verbose:-0} + 1 ))
		;;
	-vv|-vvv|-vvvv|-vvvvv)
		verbose=$(( ${verbose:-0} + ${#1} - 1 ))
		;;
	-?*)
		echo "Unknown option: $1" >&2
		usage 1
		;;
	*)
		break
		;;
esac; shift; done
[ -z "$datamode" ] || [ "$heads$leaves$deps$dependents$series" = "1" ] ||
	die "mutually exclusive options: --series --deps --heads --leaves --dependents"
[ $# -gt 0 ] || set -- HEAD
[ $# -eq 1 ] || die "name already specified ($1)"
name="$1"

process_dep()
{
	if [ -n "$_dep_is_tgish" ] && [ -z "$_dep_missing$_dep_annihilated" ]; then
		printf '%s\n' "$_dep ${_depchain##* }"
	fi
}

if [ -n "$heads" ]; then
	no_remotes=1
	base_remote=
	verify="$name"
	v_verify_topgit_branch tgbranch "${name:-HEAD}" -f || tgbranch=
	[ -n "$tgbranch" ] || tgbranch="$(git cat-file blob HEAD:.topdeps 2>/dev/null | paste -d ' ' -s -)" || :
	if [ -n "$tgbranch" ]; then
		# faster version with known TopGit branch name(s)
		navigate_deps -s=-1 -1 -- "$tgbranch" | sort
		exit 0
	fi
	hash="$(git rev-parse --verify --quiet "$verify^0" --)" || die "no such commit-ish: $name"
	depslist="$(get_temp depslist)"
	tg summary --topgit-heads |
	while read -r onetghead; do
		printf '%s %s\n' "$onetghead" "$onetghead"
		recurse_deps process_dep "$onetghead"
	done | sort -u >"$depslist"
	git branch --no-color --contains "$hash" | cut -c 3- |
	join -o 2.2 - "$depslist" |
	sort -u
	exit 0
fi

v_cntargs() { eval "$1=$(( $# - 1 ))"; }
if [ -n "$series" ]; then
	if [ -z "$serieshead" ]; then
		v_verify_topgit_branch name "${name:-HEAD}"
		heads="$(navigate_deps -s=-1 -1 -- "$name" | sort | paste -d ' ' -s -)" || heads="$name"
		v_cntargs headcnt $heads
		if [ "$headcnt" -gt 1 ]; then
			err "multiple heads found"
			info "use the --series=<head> option on one of them:" >&2
			for ahead in $heads; do
				info "$tab$ahead" >&2
			done
			die "--series requires exactly one head"
		fi
		[ "$headcnt" = 1 ] || die "programmer bug"
		serieshead="$heads"
	else
		v_verify_topgit_branch serieshead "$serieshead"
		v_verify_topgit_branch name "${name:-HEAD}" -f || name=
	fi
	seriesf="$(get_temp series)"
	recurse_deps_internal --series -- "$serieshead" | awk '{print $0 " " NR}' | sort >"$seriesf"
	refslist=
	[ -z "$tg_read_only" ] || [ -z "$tg_ref_cache" ] || ! [ -s "$tg_ref_cache" ] ||
	refslist="-r=\"$tg_ref_cache\""
	flagname=
	[ -z "$name" ] || [ "$serieshead" = "$name" ] || flagname="$name"
	output() {
	eval run_awk_topgit_msg -n -nokind "$refslist" '"refs/$topbases"' |
	join "$seriesf" - | sort -k2,2n | awk -v "flag=$flagname" '
	{
		bn = $1
		mark = ""
		if (flag != "") mark = (bn == flag) ? "* " : "  "
		bn = mark bn
		desc = $0
		sub(/^[^ ]+ [^ ]+ /, "", desc)
		printf "%-39s\t%s\n", bn, desc
	}
	'
	} && page output
	exit 0
fi

v_verify_topgit_branch name "${name:-HEAD}"

if [ -n "$leaves" ]; then
	find_leaves "$name"
	exit 0
fi

if [ -n "$deps$dependents" ]; then
	alldeps="$(get_temp alldeps)"
	tg --no-pager summary --tgish-only --deps >"$alldeps" || die "tg summary --deps failed"
	if [ -n "$deps" ]; then
		awk -v annb="$name" 'NF == 2 && $2 != "" && $1 == annb { print $2 }' <"$alldeps"
	else
		awk -v annb="$name" 'NF == 2 && $1 != "" && $2 == annb { print $1 }' <"$alldeps"
	fi
	exit 0
fi

base_rev="$(git rev-parse --short --verify "refs/$topbases/$name^0" -- 2>/dev/null)" ||
	die "not a TopGit-controlled branch"

measure="$(measure_branch "refs/heads/$name" "$base_rev")"

echo "Topic Branch: $name ($measure)"

read -r bkind subj <<EOT
$(run_awk_topmsg_header -kind "$name")
EOT
[ "$bkind" = "3" ] || printf "Subject: %s\n" "$subj"

if [ "${verbose:-0}" -ge 1 ]; then
	scratch="$(get_temp scratch)"
	printf '%s\n' "$name" >"$scratch"
	dependents="$(get_temp dependents_list)"
	tg summary --tgish-only --deps | sort -k2,2 | join -1 2 - "$scratch" | cut -d ' ' -f 2 | sort -u >"$dependents"
	if ! [ -s "$dependents" ]; then
		echo "Dependents: [none]"
	else
		if [ "${verbose:-0}" -le 1 ]; then
			sed '1{ s/^/Dependents: /; n; }; s/^/            /;' <"$dependents"
		else
			minwidth=0
			while read -r endent; do
				[ ${#endent} -le $minwidth ] || minwidth=${#endent}
			done <"$dependents"
			prefix="Dependents:"
			while read -r endent; do
				ood=
				contained_by "refs/heads/$name" "refs/$topbases/$endent^0" || ood=1
				if [ -n "$ood" ]; then
					printf '%s %-*s [needs merge]\n' "$prefix" $minwidth "$endent"
				else
					printf '%s %s\n' "$prefix" "$endent"
				fi
				prefix="           "
			done <"$dependents"
		fi
	fi
fi

if [ "$bkind" = "3" ]; then
	echo "* No commits."
	exit 0
fi

echo "Base: $base_rev"
branch_contains "refs/heads/$name" "refs/$topbases/$name" ||
	echo "* Base is newer than head! Please run \`$tgdisplay update\`."

if has_remote "$name"; then
	echo "Remote Mate: $base_remote/$name"
	# has_remote only checks the single ref it's passed therefore
	# check to see if the remote base is present especially since remote
	# bases in the old location do not automatically fetched by default
	if ref_exists "refs/remotes/$base_remote/${topbases#heads/}/$name"; then
		branch_contains "refs/$topbases/$name" "refs/remotes/$base_remote/${topbases#heads/}/$name" ||
			echo "* Local base is out of date wrt. the remote base."
	else
		echo "* Remote base ($base_remote/${topbases#heads/}/$name) is missing."
	fi
	branch_contains "refs/heads/$name" "refs/remotes/$base_remote/$name" ||
		echo "* Local head is out of date wrt. the remote head."
	branch_contains "refs/remotes/$base_remote/$name" "refs/heads/$name" ||
		echo "* Local head is ahead of the remote head."
fi

git cat-file blob "$name:.topdeps" 2>/dev/null |
awk 'NR == 1 {print "Depends: " $0} NR != 1 {print "         " $0}'

depcheck="$(get_temp tg-depcheck)"
missing_deps=
needs_update "$name" >"$depcheck" || :
if [ -n "$missing_deps" ]; then
	echo "MISSING: $missing_deps"
fi
depcheck2="$(get_temp tg-depcheck2)"
sed '/^!/d' <"$depcheck" >"$depcheck2"
if [ -s "$depcheck2" ]; then
	echo "Needs update from:"
	# 's/ [^ ]* *$//' -- last is $name
	# 's/^[:] /::/'   -- don't distinguish base updates
	<"$depcheck2" sed -e 's/ [^ ]* *$//' -e 's/^[:] /:/' |
		while read dep chain; do
			extradep=
			case "$dep" in
				::*)
					dep="${dep#::}"
					fulldep="refs/heads/$dep"
					extradep="refs/$topbases/$dep"
					;;
				:*)
					dep="${dep#:}"
					fulldep="$dep"
					;;
				*)
					fulldep="refs/heads/$dep"
					;;
			esac
			printf '%s' "$dep "
			[ -n "$chain" ] && printf '%s' "(<= $(echol "$chain" | sed 's/ / <= /')) "
			printf '%s' "($(eval measure_branch '"$fulldep"' '"refs/heads/$name"' ${extradep:+\"\$extradep\"}))"
			echo
		done | sed 's/^/	/'
else
	echo "Up-to-date${missing_deps:+ (except for missing dependencies)}."
fi
