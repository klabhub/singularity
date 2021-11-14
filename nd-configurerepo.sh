#!/bin/bash
#emacs: -*- mode: shell-script; c-basic-offset: 4; tab-width: 4; indent-tabs-mode: nil -*-
#ex: set sts=4 ts=4 sw=4 et:

# Depends:
#   assumes to be present:
#     apt
#   installs if needed if NEURODEBIAN_INSTALL=1:
#     python, wget, gnupg, dirmngr (when older gnupg)
# Recommends: netselect

# play safe
set -e
set -u

############
# Defaults #
############


nd_aptenable_version=0.1

nd_key_id=0xA5D32F012649A5A9
nd_config_url=https://raw.githubusercontent.com/neurodebian/neurodebian/master/neurodebian.cfg
nd_config_file=/etc/neurodebian/neurodebian.cfg
nd_mirror_origin=http://neuro.debian.net/debian
nd_mirror_default=$nd_mirror_origin # or may be AWS?

# To be set by cmdline args or via env variables with prefix NEURODEBIAN_
ae_release=${NEURODEBIAN_RELEASE:-}
ae_components=${NEURODEBIAN_COMPONENTS:-software,data}
ae_flavor=${NEURODEBIAN_FLAVOR:-}
ae_mirror=${NEURODEBIAN_MIRROR:-best}
ae_suffix=${NEURODEBIAN_SUFFIX:-}
ae_verbose=${NEURODEBIAN_VERBOSE:-1}
ae_overwrite=${NEURODEBIAN_OVERWRITE:-}
ae_sources=${NEURODEBIAN_SOURCES:-}
ae_install=${NEURODEBIAN_INSTALL:-}
ae_update=${NEURODEBIAN_UPDATE:-1}
ae_dry_run=${NEURODEBIAN_DRY_RUN:-}
ae_defun_only=${NEURODEBIAN_DEFUN_ONLY:-} # mode to source this file as a "library"

ae_sudo=
exe_dir=$(dirname $0)
do_print_release=
do_print_flavor=

# TODOs:
# - apt priority! (so we could avoid automagic upgrades etc)
# - multiarch setups

if [ -z "${NEURODEBIAN_TEMPDIR:-}" ]; then
    ae_tempdir=$(mktemp -d)
    trap "rm -rf \"$ae_tempdir\"" TERM INT EXIT
else
    # reuse the same directory/fetched configuration if was specified
    ae_tempdir="${NEURODEBIAN_TEMPDIR:-}"
fi


nd_config_file_fresh="$ae_tempdir/neurodebian.cfg"

print_verbose()
{
    level=$1; shift
	if [ "$ae_verbose" -ge $level ]; then
        # use stderr for printing within functions stdout of which might be used
        echo -n "I: " >&2
        i=1; while [ $i -lt $level ]; do echo -ne " ">&2; i=$(($i+1)); done
        echo -e "$*" >&2
    fi
}

error()
{
    code=$1; shift
	echo -e "E: $*" >&2
    exit $code
}

print_version()
{
    cat << EOT
nd-configurerepo $nd_aptenable_version

Copyright (C) 2014 Yaroslav Halchenko <debian@onerussian.com>

Licensed under GNU Public License version 3 or later.
This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

Written by Yaroslav Halchenko for the NeuroDebian project.

EOT
}

eval_dry()
{
    if [ -z "$ae_dry_run" ]; then
        if eval "$ae_sudo $@" 1>|"$ae_tempdir/eval.log" 2>&1; then
            rm "$ae_tempdir/eval.log"
        else
            error $? "Command $@ failed with exit code $?.  Output was: `cat $ae_tempdir/eval.log`"
        fi
    else
        echo "DRY: $@" >&2
    fi
}

print_help()
{
    cat << EOT

Usage:  nd-configurerepo [options]

Enables NeuroDebian repository for the current Debian or Ubuntu release.

Options:

  -r, --release=RELEASE
    Name of the Debian/Ubuntu release to be used. If not specified,
    it is deduced from the 'apt-cache policy' output, by taking repository
    of Debian or Ubuntu origin with highest priority.

  --print-releases
    Print a list of releases present in NeuroDebian repository.

  --print-release
    Print the release deduced from the output of apt-cache policy.

  -f, --flavor=full|libre
    Which flavor of the repository should be enabled:

      libre  Only 'main' component, containing only DFSG-compliant content.
      full   Includes 'main', 'contrib', and 'non-free'.

    If not specified -- deduced from the output of apt-cache policy.

  --print-flavor
    Print the flavor deduced from the output of apt-cache policy.

  -c, --components=c1,c2,c3
    Comma separated list of components to enable among:

     software  primary software repository
     data      data packages
     devel     "overlay" of development versions (like Debians' "experimental").
               Not sufficient on its own and available only from the main site

    If not specified -- "software,data"

  -m, --mirror=NAME|URL
    Which mirror to use. Could be a mirror code-name (as specified in
    /etc/neurodebian/neurodebian.cfg), or a URL.

  --print-mirrors
    Return a list (with abbreviation) of known NeuroDebian mirrors.

  --overwrite,
    If apt file already present, it would not be overridden (by default).
    Use this option to overwrite.

  --suffix=SUFFIX
    Which suffix to add to the apt file, in case you are trying to enable
    multiple repositories

  --sources, --no-sources
    Either to enable deb-src lines. If none specified -- would be enabled if
    sources for a core package (apt) are available.

  -n, --dry-run
    Do not perform any changes -- generated configurations and commands will
    simply be printed to stdout

  --install
    If found absent, all necessary tools (wget, netselect) if available will
    be apt-get installed

  -v, --verbose
    Enable additional progress messages. Could be used multiple times

  -q, --quiet
    Make operation quiet -- only error messages would be output

  -h, --help
    Print short description, usage summary and option list.

  --version
    Print version information and exit.

Exit status:

  non-0 exit status in case of error.
  Error exit code would depend on which command has failed.

Examples:
  nd-configurerepo
    Enable software and data components from the optimal (according to
    netselect) mirror.  Some information about progress will be printed

  nd-configurerepo -q --suffix=-devel -c devel
    Quietly enable -devel repository for the current release, and place apt
    configuration into /etc/apt/sources.list.d/neurodebian.sources-devel.list

  nd-configurerepo -q --suffix=-de-sid-full -c software,data,devel -m jp
    Force sid distribution, all the components, from the Japan mirror
EOT
}

get_neurodebian_cfg()
{
    if [ -s "$nd_config_file_fresh" ]; then
        print_verbose 3 "Config file $nd_config_file_fresh exists -- not fetching"
        echo "$nd_config_file_fresh"
        return 0
    fi
    # First we try to fetch the most recent version from the github
    print_verbose 3 "Fetching config file from the github repository"
    assure_command_from_package wget wget 1
    wget --no-check-certificate -c -q -O$nd_config_file_fresh \
        $nd_config_url \
        && { echo "$nd_config_file_fresh"; } \
        || { [ -e "$nd_config_file" ] \
             && echo "$nd_config_file" \
             || error 10 "Neither could fetch $nd_config_url, nor found $nd_config_file"; }
}

query_cfg_section()
{
    config_file="$1"
    section="$2"
    print_verbose 3 "Querying config $config_file section $section"
    assure_command_from_package python python-minimal 1
    python -c "from ConfigParser import SafeConfigParser as SP; cfg = SP(); cfg.read('$config_file'); print('\n'.join([' '.join(x) for x in cfg.items('$section')]))"
}

get_mirrors()
{
    nd_config=`get_neurodebian_cfg`
#    $exe_dir/nd_querycfg -F" " --config-file="$nd_config" "mirrors" \
    n=""
    query_cfg_section "$nd_config" "mirrors" \
    | while read mirror_name mirror_url; do
        # verify that url is just a url
        if echo "$mirror_url" | grep -v -e '^[a-z0-9:+]*://[-+_%.a-z0-9/]*$'; then
            print_verbose 1 "Mirror $mirror_name has 'illegit' URL: $mirror_url.  Skipping"
        fi
        [ -z "$n" ] || echo -ne "${ND_IFS:-\n}"; n+=1
        echo -n "$mirror_name $mirror_url"
    done
}

get_releases()
{
    nd_config=`get_neurodebian_cfg`
    n=""
    query_cfg_section "$nd_config" "release files" \
    | while read release_name release_url; do
        # verify that url is just a url
        if [ "$release_name" = "data" ]; then
            # skip data
            continue
        fi
        [ -z "$n" ] || echo -ne "${ND_IFS:-\n}"; n+=1
        echo -n "$release_name"
    done
}

get_package_version()
{
    pkg_version=$(apt-cache policy "$1" | awk '/^ *Installed:/{print $2;}')
    [ "$pkg_version" != '(none)' ] || pkg_version=''
    echo "$pkg_version"
}

netselect_mirror() {
    # select "closest" mirror according to netselect.
    print_verbose 2 "Selecting the 'best' mirror using netselect"
    assure_command_from_package netselect
    if ! which netselect >&/dev/null; then
        print_verbose 1 "netselect (apt-get install netselect) needed to select the 'best' mirror was not found"
        print_verbose 1 "Selecting the default repository: $nd_mirror_default"
        echo $nd_mirror_default
    else
        # squeeze version doesn't have -D yet to force output of the URL not IP, but for our mirrors ATM it shouldn't matter
        netselect_opts="-s 1"
        netselect_version="$(get_package_version netselect)"
        if dpkg --compare-versions "$netselect_version" ge 0.3.ds1-17; then
            netselect_opts+=" -D"
        fi
        if dpkg --compare-versions "$netselect_version" ge 0.3.ds1-15; then
            netselect_opts+=" -I"
        fi
        best_mirror=$(get_mirrors | awk '{print $2;}' | eval $ae_sudo xargs netselect $netselect_opts | awk '{print $2;}')
        if [ -z "$best_mirror" ]; then
            print_verbose 1 "Failed to select mirror using netselect. Selecting default one ($nd_mirror_default)"
            echo "$nd_mirror_default"
        else
            print_verbose 2 "Best mirror: $best_mirror"
            echo $best_mirror
        fi
    fi
}

get_mirror_url()
{
    # given mirror alias -- find its url
    url=$(get_mirrors | awk "/^$1 /{print \$2;}")
    if [ -z "$url" ]; then
        error 9 "Cannot resolve mirror $1 to the URL"
    fi
    echo $url
}

get_apt_policy()
{
    # Get apt-cache policy output in a single list for matching suites
    # (could be a separated with \| or , for multiple choices, e.g.
    #
    # get_apt_policy Debian,Ubuntu
    # or
    # get_apt_policy NeuroDebian
    suites="$1"
    $ae_sudo apt-cache policy | grep -B1 -e "o=\(${suites//,/\\|}\)" | tr '\n' ' ' | sed -e 's, -- ,\n,g' | grep -v -e '-\(updates\|security\)' | sort -nr
}

is_component_included()
{
    echo "$ae_components" | tr ',' '\n' | grep -q "^$1\$"
}

is_sources_enabled()
{
    apt-cache showsrc apt >&/dev/null && echo 1 || echo 0
}

assure_command_from_package()
{
    cmd=$1
    pkg=${2:-$cmd}
    fail=${3:-}

    which "$cmd" >&/dev/null && return 0

    # if absent -- check availability of the package
    apt_cache=$(LANG=C apt-cache policy "$pkg" 2>&1)
    if [[ "$apt_cache" =~ Unable\ to\ locate\ package ]] || [[ "$apt_cache" =~ Candidate:\ (none) ]] \
       || [[ "$apt_cache" =~ is\ not\ available ]] ; then
        print_verbose 1 "Package $pkg providing command $cmd is N/A. Skipping"
        return 10;
    fi
    if echo "$apt_cache" | grep -q '^\s*\*\*\*'; then
        print_verbose 1 "WARNING -- command $cmd is N/A but package $pkg is claimed to be installed"
        [ -z "$fail" ] && return 11 || error $fail "Command $cmd is required to proceed"
    fi
    if [ "$ae_install" = "1" ]; then
        print_verbose 1 "Installing $pkg package to get $cmd command"
        eval_dry DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
        return
    else
        print_verbose 1 "Command $cmd (from package $pkg) is N/A."
        print_verbose 1 "Use with --install to get all necessary packages installed automatically"
        [ -z "$fail" ] && return 12 || error $fail "Command $cmd is required to proceed"
    fi
}

# if it was requested -- return without doing anything
[ -z "$ae_defun_only" ] || return

#
# Commandline options handling
#

# Parse commandline options (taken from the getopt examples from the Debian util-linux package)
# Note that we use `"$@"' to let each command-line parameter expand to a
# separate word. The quotes around `$@' are essential!
# We need CLOPTS as the `eval set --' would nuke the return value of getopt.
CLOPTS=`getopt -o h,r:,m:,f:,c:,q,v,n --long help,version,quiet,verbose,mirror:,release:,flavor:,components:,suffix:,overwrite,sources,no-sources,install,dry-run,do-not-update,print-releases,print-release,print-mirrors,print-best-mirror,print-flavor -n 'nd-configurerepo' -- "$@"`

if [ $? != 0 ] ; then
  error 2 "Problem with parsing cmdline.  Terminating..."
fi

# Note the quotes around `$CLOPTS': they are essential!
eval set -- "$CLOPTS"

if [ `whoami` != "root" ]; then
    ae_sudo=sudo
fi

while true ; do
  case "$1" in
	  -r|--release) shift; ae_release="$1"; shift;;
	  -f|--flavor) shift;  ae_flavor="$1"; shift;;
	  -c|--components) shift; ae_components="$1"; shift;;
      -m|--mirror) shift;  ae_mirror="$1"; shift;;
         --print-mirrors)  get_mirrors; exit 0;;
         --print-best-mirror)  netselect_mirror; exit 0;;
         --print-releases)  get_releases; exit 0;;
         --print-release)  do_print_release=1; shift;;
         --print-flavor)  do_print_flavor=1; shift;;
      -n|--dry-run)        ae_dry_run=1; shift;;
         --suffix) shift;  ae_suffix="$1"; shift;;
         --overwrite)      ae_overwrite="$1"; shift;;
         --do-not-update)  ae_update=0; shift;;
         --sources)        ae_sources=1; shift;;
         --no-sources)     ae_sources=0; shift;;
         --install)        ae_install=1; shift;;
	  -q|--quiet)          ae_verbose=0; shift;;
	  -v|--verbose)        ae_verbose=$(($ae_verbose+1)); shift;;
	  -h|--help) print_help; exit 0;;
	  --version) print_version; exit 0;;
	  --) shift ; break ;;
	  *) error 1 "Internal error! ($1)";;
  esac
done


if [ $# -gt 0 ] ; then
    print_help >&2
    exit 2
fi

# Inform!
[ -z "$ae_sudo" ] || print_verbose 1 "This script requires root access.  Since current user is not root, sudo will be used"

#
# Basic system/environment knowledge
#

ae_output_file=/etc/apt/sources.list.d/neurodebian.sources${ae_suffix}.list

apt_policy=$(get_apt_policy "Debian,Ubuntu" )

if [ -z "$ae_release" ]; then
    ae_release=$(echo "$apt_policy" | head -1 | sed -e 's/.*,n=\([^,]*\),.*/\1/g')
    if [ ! -z "$do_print_release" ]; then
        echo $ae_release
        exit 0
    fi
fi

if [ -z "$ae_flavor" ]; then
    ae_flavor=$(echo "$apt_policy" | grep -e ",n=$ae_release," | grep -qe 'c=\(non-free\|multiverse\)' && echo "full" || echo "libre")
    if [ ! -z "$do_print_flavor" ]; then
        echo $ae_flavor
        exit 0
    fi
fi

#
# Determine which mirror to use
#

# knowing mirror is not necessary for -devel available only from the main site
if is_component_included software || is_component_included data; then
    # for now just use default
    if [ -z "$ae_mirror" ]; then # none specified
        ae_mirror_url=$nd_mirror_origin
    else
        if ! [[ "$ae_mirror" =~ .*://.* ]]; then
            case "$ae_mirror" in
                best)    ae_mirror_url=$(netselect_mirror);;
                default) ae_mirror_url=$nd_mirror_default;;
                origin)  ae_mirror_url=$nd_mirror_origin;;
                *)       ae_mirror_url=$(get_mirror_url "$ae_mirror");;
            esac
        else
            ae_mirror_url="$ae_mirror" # it was some kind of a URL already
        fi
    fi
fi

#
# Prepare APT file
#

case $ae_flavor in
 full)  apt_flavor="contrib non-free";;
 libre) apt_flavor="";;
 *) error 7 "Unknown value of flavor $apt_flavor.  Must be full or libre"
esac

if [ -z "$ae_sources" ]; then
    ae_sources=$(is_sources_enabled)
fi

if [ $ae_sources -eq 0 ]; then
    sources_comment="#"
else
    sources_comment=""
fi

apt_list=

if is_component_included software; then
    apt_list+="
# NeuroDebian software repository
deb     $ae_mirror_url $ae_release main $apt_flavor
${sources_comment}deb-src $ae_mirror_url $ae_release main $apt_flavor
"
fi

if is_component_included data; then
    apt_list+="
# NeuroDebian data repository
deb     $ae_mirror_url data main $apt_flavor
${sources_comment}deb-src $ae_mirror_url data main $apt_flavor
"
fi

if is_component_included devel; then
    apt_list+="
# NeuroDebian -devel repository
deb     http://neuro.debian.net/debian-devel $ae_release main $apt_flavor
${sources_comment}deb-src http://neuro.debian.net/debian-devel $ae_release main $apt_flavor
"
fi

if [ -e "$ae_output_file" ] && [ -z "$ae_overwrite" ]; then
    if diff "$ae_output_file" <(echo "$apt_list") | grep -q .; then
        # error 3
        print_verbose 1 "File $ae_output_file already exists, containing:\n`cat \"$ae_output_file\"`\n\nI: New configuration is different:\n$apt_list"
        if get_apt_policy NeuroDebian >/dev/null; then
            print_verbose 1 "NeuroDebian repositories are already available, thus skipping the rest."
            print_verbose 1 "Rerun with --overwrite if you would like to reconfigure."
            exit 0
        else
            print_verbose 1 "NeuroDebian configuration is found but not yet available -- continuing with new configuration."
        fi
    else
        print_verbose 1 "New configuration is identical to existing and NeuroDebian repository is already enabled."
        print_verbose 1 "Skiping the rest. Rerun with --overwrite if you would like to reconfigure."
        exit 0
    fi
else
    print_verbose 1 "Generating $ae_output_file"
    if [ -z "$ae_dry_run" ]; then
        echo "$apt_list" | $ae_sudo bash -c "cat - >| '$ae_output_file'"
    else
        echo "DRY:"
        echo "$apt_list"
    fi
fi


#
# Assure present archive GPG key for APT system
#

# Figure out if key needs to be imported (if ran within package,
# should already be there due to neurodebian-archive-keyring package)

# Ideas taken from neurodebian-docker setup to guarantee correct apt-key functioning
# gnupg needed by apt-key might not yet be installed
assure_command_from_package gpg gnupg 1
# Ubuntu includes "gnupg" (not "gnupg2", but still 2.x), but not dirmngr, and gnupg 2.x requires dirmngr
# so, if we're not running gnupg 1.x, explicitly install dirmngr too
gpg --version | grep -q '^gpg (GnuPG) 1\.' || assure_command_from_package dirmngr dirmngr 1

if LANG=C eval $ae_sudo apt-key export $nd_key_id 2>&1 1>/dev/null | grep -qe "nothing exported"; then
    print_verbose 1 "Fetching the key from the server"
    APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1
    export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE
    eval_dry  apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com $nd_key_id
fi


#
# Finalizing (apt-get update etc)
#

if [ "$ae_update" = "1" ]; then
    print_verbose 1 "Updating APT listings, might take a few minutes"
    if [ -z "$ae_dry_run" ]; then
        apt_logfile="$ae_tempdir/apt.log"
        $ae_sudo apt-get update 1>"$apt_logfile" 2>&1 \
            && rm -f "$apt_logfile" \
            || {
                 apt_log=$(cat "$apt_logfile")
                 print_verbose 0 "$apt_log"
                 if echo "$apt_log" | grep -q "Malformed line [0-9]* in source list $ae_output_file"; then
                     $ae_sudo mv "${ae_output_file}" "${ae_output_file}-failed.disabled"
                     error 6 "Update failed to possible errorneous APT listing file produced by this script.  Generated $ae_output_file renamed to ${ae_output_file}-failed.disabled to not interfer"
                 fi
                 # TODO: too late for $? -- need to store right after apt-get update run
                 #       log file would get removed, so not worth bringin it up
                 error 5 "Update failed with exit code $?."
                 }
    else
        eval_dry apt-get update # --no-allow-insecure-repositories
    fi
else
    print_verbose 1 "apt-get update  was not run. Please run to take an effect of changes"
fi

if [ "$ae_verbose" -ge 2 ]; then
    print_verbose 2 "Currently enabled NeuroDebian suites/mirrors:"
    get_apt_policy NeuroDebian
fi