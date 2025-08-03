#!/bin/env bash
# This script is designed to work only with recent bash implementations, not busybox/ash/dash etc...

# BEWARE - THIS IS SYMLINKED TO FROM THE NETRIX REPO ON DGC'S DESKTOP
#           IF YOU EDIT IT THERE IT ALSO CHANGES THE MASTER ONE

# @FIXME DGC 6-May-2022
#           This script has a large issue, which I have failed to notice ( or to fix ) earlier.
#           It does a very bad job of labelling hourly/daily etc jobs with an 'execution time.
#
#           When the crontab says:
#               17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
#               25 6    * * *   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.daily )
#               47 6    * * 7   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.weekly )
#               52 6    1 * *   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.monthly )
#            but we don't have anacron,
#            you would hope the four lines above would put
#                17 minutes past each hour
#                25 minutes past 6
#             and so on as the execution times, but what we get is:
#                executable              | /etc/cron.hourly/    | at-same-min-each-hour                    root  /etc/cron.hourly/logrotate
#                executable              | cron.d/php5          | 9,39                   *   *    *   *    root  [ -x /usr/lib/php5/sessionclean ] && /usr/lib/php5/sessionclean
#                NOT EXECUTABLE          | /etc/cron.daily/     |                                          root  /etc/cron.daily/apt
#                executable              | /etc/cron.daily/     |                                          root  /etc/cron.daily/aptitude
#            which is not much use.


# @file      show-cron-jobs.sh
#
#             published at:
#               https://gist.github.com/myshkin-uk/d667116d3e2d689f23f18f6cd3c71107
#
#             @NOTE DGC 2-Sep-2019
#                      There is one comment there that "the script doesn't run as expected".
#                      I have no idea what to make of that rather cryptic report.
#                      This is such a difficult task it may need fixing for ol/new bash versions
#                       and a million other local difficulties.

version=30       # IF YOU CHANGE THIS YOU MUST ADD A LINE TO '# Version changes' BELOW

#
# @param     Any parameter enables 'helpful output' as well as the the result table.
#            A single 'p' parameter also enables 'progress lines'.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
#  INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES
#  OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
#  WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
#  ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# @author    DGC after yukondude
#             email me at from_scj_snippet@myshkin.me

# @NOTE DGC 8-Jan-2019
#           This file is based on a much simpler example picked up from
#               https://stackoverflow.com/questions/134906/how-do-i-list-all-cron-jobs-for-all-users/53892185#53892185
#            authored by yukondude.
#
#           It has now evolved into a perfect example of tasks which should not be done in bash.
#
#           It uses a pile of intermediate temporary files, which we do our best to clear up on exit
#            but may still be left cluttering the place up after errors and problems.
#
#           The right way to do it is to store the info about tasks in an array of structs.
#           The bash code could be improved to use a one-dimensional array,
#            but it can't go as far as structs.
#
#           This really needs re-writing in a more capable language.

# @FIXME DGC 8-Jan-2021 ( nice coincidence )
#           custom crontab files can include a PATH= line.
#           we try to find ( using which ) the executable so we can mark it as 'executable' or 'non-executable'
#            but our code failes in those circumstances.
#           we do stick '??on custom path??' in the field - but it isn't a proper solution.

# Version changes
#     11  Tidier comments
#         Drop empty columns in output when no numeric timings are shown.
#     12  Fix case-disregard on dow and moy strings.
#         Fix detection of untranslated numeric timings.
#     13  Tell user about waiting 'at-jobs'.
#     14  A version which works on DX3
#     15  One more go at sorting out hourly tasks and anacron
#     16  Fudge-up anacron base delays.
#     17  Accommodate versions of run-parts which allow . characters in file names.
#     18  Fix handling of dow = 1,2,3,4,5
#     19  Abortive attempt to keep work files when being run by from our offices.
#     20  Spot lines of the form:
#              2  21 1-7 * *     root       [ "$(/bin/date +\%a)" -eq "Fri" ] && vacuum-index-values-and-alarms.php
#           both numeric and locale-english versions.
#           and output 'first Friday of the month at ...'
#     21  Fix path-analysis of the first-week-of-the-month lines we now support
#     22  Support both orderings of 'first week of month' tests - and make quotes around operands fully optional.
#     23  Suppress mention of disabled cron test tasks.
#     24  Spot, moan about and quit if the busybox system is operational.
#     25  Moved any temporary non-volatile files script is asked to create to a single directory under /tmp
#     26  Add handling for --version command line switch
#     27  Add summary list of systemd timers.
#     28  ?
#     29  split list into active and inactive tasks
#     30  fillet out test-cron*.sh files

if [ "1" = "$#" ] && [ "--version" = "$1" ]
then
    echo "version 1.${version}"
    exit
fi

# I have given up on this 'run by author' piece of code.
# I only intend it to control whether we leave the intermediate files around for debugging purposes anyway.
#
# If you run a script non-sudo, the variable $SSH_CLIENT will give you the address
#  from which the current ssh session was initiated.
# That doesn't work from a sudo script, and I haven't looked into whether I can get around it.
# There is a 'pinky' command which should help, but says we are at 128.55.187.81.in-addr.arpa
#  apparently that can do better if reverse DNS is properly set up.
# We COULD mandate that the user passes us the variable as the first parameter to this script,
#  but that's too clunky to bother with right now.
#
runByAuthor=false

echo
echo -n "show-cron-jobs version ${version}"
if $runByAuthor
then
    echo -n " being run by author."
fi
echo
echo

if [ "root" != "$(whoami)" ]
then
    echo "This script can only run as root - quitting."
    exit
fi

                                                                                                                # shellcheck disable=SC2086
{
    scriptFN="$(basename $0)"
    scriptAPADN="$(dirname "$(readlink -f $0)")"            # The location of this script as an absolute path. ( e.g. /home/Scripts )
    scriptAPAFN="${scriptAPADN}/${scriptFN}"
}


# Where the script is running
currentWorkingAPADN="$(pwd)"

# Any   parameter on the command line requests noisy            mode.
# A 'p' parameter on the command line requests show-my-progress mode.
#
quiet=true
showProgress=false
if [ '0' != "$#" ]
then
    quiet=false

    if [ 'p' == "$1" ]
    then
        showProgress=true
    fi
fi

#set -e
#set -x

# DEXDYNE SPECIFIC - REMOVE IF YOU DON'T NEED IT 
#
# This script is NOT intended to run on busybox.
# We have a system which uses the /var/spool/crontab/root file to run scripts
#  in /etc/dexdyne/root-cron-scripts/every-minute/ and so on.
# But that feature should not be present on non-busybox systems
#
rootCrontabAPAFN="/var/spool/cron/crontabs/root"

if   [ -f ${rootCrontabAPAFN} ]                                    \
  && grep -q "/etc/dexdyne/root-cron-scripts" ${rootCrontabAPAFN}
then
    echo "The special busybox system for running root cron tasks is present and should not be"
    echo " please edit/remove the file ${rootCrontabAPAFN}"
    echo ""
    echo " quitting."
    echo
    exit 1
fi

# Knowing the size of the terminal can be useful for formatting.
#
screenColumns="$(tput cols )"
screenRows="$(   tput lines)"

screenWidthSeparator="$(printf "%0.s-" $(seq 1 ${screenColumns}))"

if ! ${quiet}
then
    cat << EOS

                       Use the command with no parameters to suppress this message.

WARNING - this script is clever, but not as clever as you might hope.
          It now examines the executables invoked by each cron line, and tries to warn you if they are
           not executable.
           not present where they are expected to be.
          Now there is another thing which can go wrong we we do not yet check,
           which is that the executable may be present and executable by root
           but not by the user which is scheduled to run it.
          You might hope that something on the lines of:
              if [ 'yes' = "\$(sudo -u ${user} bash -c "if [ -x ${executableAPAFN} ] ; then echo 'yes' ; else echo 'no'; fi")" ]
           would accomplish the required test. But it doesn't.
          It turns out that [ -x ] only ever tests the permission bit, and ignores the directory and file rights
           to say nothing of the fact that entire filesystems can be mounted as 'non-executable'.
          So it is not within our reasonable aspirations to spot a situation where a cron task cannot run for
           anything but the simplest reasons.
========================================================================================================================

EOS
fi

# This is awful.
# The official manual for run-parts says that by default it only runs files whose name fits a very restricted pattern,
#  and that patter does NOT include the . character so xxx.sh scripts will not be run.
#  ( It also supports switches to alter this behaviour,
#     but this script is not sophisticated enough to deal with that complication )
# However I find that on a number of our machines this rule is not obeyed.
#  Whatever it is that calls itself 'run-parts' does not even support the --version switch ( !!! )
#   and it happily runs .sh stuff - particularly obvious for /etc/cron.daily/man-db.cron
# So I have added this test to find out in-anger how the utility on THIS machine behaves.
#
runPartsExcludesPeriods=true

# WARNING - this test assumes you have NOT removed the .sh from the end of the name of this script !!!!!!

if run-parts --test ${scriptAPADN} | grep -q "${scriptFN}"
then
    runPartsExcludesPeriods=false
fi

if ! ${quiet}
then
    echo
    echo -n "Have detected that the run-parts utility on this computer "

    if ${runPartsExcludesPeriods}
    then
        echo -n "ignores"
    else
        echo -n "runs"
    fi

    echo " files with full-stop (period) characters in their name."
    echo
fi

# Look at a filename and work out whether it matches the pattern for those which run-parts will execute.
#
# This uses a regex allowing only:
#     upper and lower case letters
#     digits
#     underscores
#     minus signs
#   and specifically excluding . characters!
#  because run-parts only runs files whose names match that rule.
#
# @param  fPAN    A file name, optionally with a leading path which we ignore.
#
# @return    Bash result code for 'happy' if file name will be executed.
#
function filenameWillBeProcessedByRunParts()
{
    if ! ${runPartsExcludesPeriods}
    then
        # For now I'm assuming that if it allows period it allows any-old-junk
        # Actually some versions of run-parts have other types of test where they
        #  O Allow you to specify a regex to be used     ( --regex    )
        #  O Examine the name for 'dpkg'-related stuff   ( --lsbyinit )
        #
        return $(true)    # code for happy.
    fi

    local fPAN="$1"; shift

    basename "${fPAN}" | grep -qE '^[A-Za-z0-9_-]*$'

    # Function returns the result code of that grep
}

# System-wide crontab file and cron job directory. Should be standard.
#
mainCrontabAPAFN='/etc/crontab'

# I don't know where to mention this, but I'll do it here....
#  files in /etc/cron.d are crontabs, not scripts,
#  and are textually included in the main crontab
#  so the executable status of the file is not significant - it goes in regardless.
#
cronExtensionsMainAPADN='/etc/cron.d'

# If we are running on busybox the 'cron extensions' feature may not exist - /etc/crontab is all you have.
#  I'm going to assume the presence or absence of this directory is a valid test for that situation.
# I beleive that if cron.d extensions don't run, then neither will the per-user crontabs.
#
cronExtensionsWillRun=false
if [ -d "${cronExtensionsMainAPADN}" ]
then
    cronExtensionsWillRun=true
fi

# Anacron is a scheme for implementing hourly/daily/weekly and monthly cron tasks.
#  but with a bit more sophistication than simply scheduling them in the main cron tab ( or cron.d dirs ).
#
# I find that it is invoked as follows:
#  Searching /etc/cron.d is the default behaviour of the cron daemon
#   and files there simply extend the main cron file.
#
#  We find there is a script
#     /etc/cron.d/0hourly
#   which simply runs, as root, all scripts in /etc/cron.hourly
#   NB there are no further scripts for other (longer) intervals,
#    any such intervals are cascaded from with the hourly handling.
#
#  In fact we often find just one hourly script, though others can be added if desired.
#     /etc/cron.hourly/0anacron
#   NB - any other hourly scripts added are NOT skipped by the logic described below to do with AC power.
#
# Now I find that 0anacron in fact has logic to:
#     Quit without acting if the daily tasks have already run today.
#     Quit without acting if a script
#         /usr/bin/on_ac_power
#      exists and when executed reports that we are not ( so I guess we are on battery )
#  If it finds no reason not to, it runs anacron, which then processes the /etc/anacrontab file.
#   this script just assumes that file contains the default instructions for daily/weekly/monthly actions.
#      There is an example in comments below - look for 'configuration file for anacron'
#
# We now try to handle main crontabs of this format - which we find on Raspberry Pi units
#  ( and other debian machines I assume ).
# They dummy up the action of the 'standard' /etc/anacrontab when no anacron is in use,
#  supporting daily/weekly/monthly actions - though without the other clever features of 0anacron.
#
# 17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
# 25 6    * * *   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.daily )
# 47 6    * * 7   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.weekly )
# 52 6    1 * *   root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.monthly )
#
# after pre-testing executability using "command -v"
#
# Note that in fact that logic is inadequate - in that what we REALLY want to look for is
#     -x /etc/cron.hourly/0anacron
#  ( and then if you want perfection 'the anacron invoked by it', which is normally
#     -x /usr/sbin/anacron
#    as above. )
#

# A file which controls the action of 'real' anacron, but which is missing in the dummied-up version.
anacrontabAPAFN='/etc/anacrontab'

# Definitions which are only utilised when anacon is in use.
anacronHourlyAPADN='/etc/cron.hourly'
anacronDailyAPADN='/etc/cron.daily'
anacronWeeklyAPADN='/etc/cron.weekly'
anacronMonthlyAPADN='/etc/cron.monthly'

anacronHourlyAPARN="${anacronHourlyAPADN}/"
anacronDailyAPARN="${anacronDailyAPADN}/"
anacronWeeklyAPARN="${anacronWeeklyAPADN}/"
anacronMonthlyAPARN="${anacronMonthlyAPADN}/"

anacronRunHourlySchedule1APAFN="${cronExtensionsMainAPADN}/0hourly"
anacronRunHourlySchedule2APAFN="${cronExtensionsMainAPADN}/anacron"

anacron0anacronAPAFN="${anacronHourlyAPARN}0anacron"

anacronSystemdTimerAPAFN="/lib/systemd/system/anacron.timer"

# 'real anacron' services only the daily, weekly and monthly directories.
#    If real anacron run 'as itself' ONLY from a cron task, the hourly directory one would not be serviced.
# Sometimes it is run by an hourly crontask which services the hourly directory,
#  and WITHIN the hourly directory it invoked 'real anacron'.
# The hourly directory can also be service under 'dummy anacron'.

runpartsEtcCronHourly=false
#
# Just test for the line in the main crontab which runs executables in cron.hourly
#  Commonly that will just be the trigger script to run 'real anacron'
#   but it is permitted to install other tasks there, and if such exist we will report on them.
#
if   cat ${mainCrontabAPAFN} | grep -qE 'run-parts.*/etc/cron\.hourly'  \
  || ! ${cronExtensionsWillRun}
then
    # We expect - that the file in cron.d will contain 'run-parts /etc/cron.hourly'
    #  and if t does that will execute any OTHER hourly tasks, as well as the anacron trigger.
    runpartsEtcCronHourly=true
fi
if   ${cronExtensionsWillRun}                        \
  && (   [ -f "${anacronRunHourlySchedule1APAFN}" ]  \
      || [ -f "${anacronRunHourlySchedule2APAFN}" ]  \
     )
then
    # We expect - that the file in cron.d will contain 'run-parts /etc/cron.hourly'
    #  and if it does that will execute any OTHER hourly tasks, as well as the anacron trigger.
    runpartsEtcCronHourly=true
fi

runningRealAnacron=false

# Only one of the following flags should be 'true - would be better to use an enum mechanism.
realAnacronUsesSystemdTimer=false
realAnacronUsesMainCrontab=false
realAnacronUsesHourlyAddition=false

runningDummyAnacron=false

dummyAnacronUsesMainCrontab=false

# This is the actual executable which 'is real anacron'
#  googling suggests it is always  ..../sbin/anacron
#  though it may be in /sbin
#                   or /usr/local/sbin
# I'm just going to assume that it is 'on the path',
#  though I can see that could possibly be untrue and anacron could still work, by using explicit paths.
#
realAnacronLocation="$(which anacron)"

if [ -n "${realAnacronLocation}" ]
then
    # There are multiple ways to run 'real anacron' - provided it is present.
    #     1. A systemd timer periodically running the executable
    #     2. invocation using @daily, @reboot in the main crontab
    #     3. invocation hourly by using:
    #            /etc/cron.d/0hourly          to add run-parts on /etc/cron.hourly, which isn't normally done by the cron daemon
    #            /etc/cron.d/anacron           is apparently an alternative name for that
    #            /etc/cron.hourly/0anacron    to run anacron once a day, when not on battery power

    if [ -f "${anacronSystemdTimerAPAFN}" ]
    then
        realAnacronUsesSystemdTimer=true
        runningRealAnacron=true

        # This is already set above, but we now know it is the case for sure:
        #
        #runpartsEtcCronHourly=false
    else
        # See whether the main crontab includes direct anacron invocation.
        #  like:
        #     @reboot /usr/local/sbin/anacron -ds
        #     @daily  /usr/local/sbin/anacron -ds
        #
        if cat ${mainCrontabAPAFN} | grep -q "in/anacron "
        then
            realAnacronUsesMainCrontab=true
            runningRealAnacron=true

            # This is already set above, but we now know it is the case for sure:
            #
            #runpartsEtcCronHourly=false
        else
            # Test for the existence of one of these 2 files:
            #     /etc/cron.d/0hourly          to add run-parts on /etc/cron.hourly, which isn't normally done by the cron daemon
            #     /etc/cron.d/anacron           is apparently an alternative name for that
            #
            if ${runpartsEtcCronHourly}
            then
                # Test for the existence of one of these 2 files:
                #     /etc/cron.d/0hourly          to add run-parts on /etc/cron.hourly, which isn't normally done by the cron daemon
                #     /etc/cron.d/anacron           is apparently an alternative name for that
                #
                if   [ -f "${anacronRunHourlySchedule1APAFN}" ]  \
                  || [ -f "${anacronRunHourlySchedule2APAFN}" ]
                then
                    # The file we found will schedule hourly execution of the next file we look for.
                    #  If we wanted to do the job properly we could peer in the one we found, and deduce the 
                    #   invoked file name EXACTLY from its contents.
                    #     /etc/cron.hourly/0anacron           This is the only name we've actually encountered, but anything COULD be used.
                    #
                    if [ ! -f "${anacron0anacronAPAFN}" ]
                    then
                        echo "System is set to trigger real anacron hourly, but the expected script file '${anacron0anacronAPAFN}' is missing."
                        echo " This is some sort of screw-up."
                    else
                        realAnacronUsesHourlyAddition=true
                        runningRealAnacron=true
                    fi
                fi
            fi
        fi
    fi
fi

if ${runningRealAnacron}
then
    if [ ! -f "${anacrontabAPAFN}" ]
    then
        # If the configuration is broken so that anacron will not be able to do anything,
        #  then in truth we should just emit MISCONFIGURED foot-high letters and exit.
        # However at present we just flag the situation and keep trying to be helpful.
        #
        # If, during our work above, we discovered that a task is doing run-parts on /etc/cron.hourly
        #  the just because anacron won't operate does not mean that any other hourly tasks are skipped
        #  so the flag 'runpartsEtcCronHourly' should not be unset here because of this failure.

        echo "System is set up to use real anacron, but the file '${anacrontabAPAFN}' is missing."
        runningRealAnacron=false
    fi
fi

if ! ${runningRealAnacron}
then
    # dummy-anacron seems to be invoked by running FOUR separate jobs in the main crontab.
    #  though running just an hourly one, and cascading the higher levels from that one would be cleaner.
    #
    # I found this system in use on the OS for the DX2 and the DX3, where it took this form:
    #
    #     m  h dom  mon dow  user  command
    #    17  *   *    *   *  root  cd / && run-parts --report /etc/cron.hourly
    #    25  6   *    *   *  root  test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.daily )
    #    47  6   *    *   7  root  test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.weekly )
    #    52  6   1    *   *  root  test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.monthly )
    #
    # That's a nice load of nonsense.
    #     1. It assumes a fixed location for the anacron exe
    #         - but it could be ( at least )
    #               /usr/local/sbin
    #            or
    #               /usr/sbin
    #
    #     2. It assumes that the mere presence of the executable is equivalent to it being 'in active use'
    #         but that will only happen via systemd, or a scheduler in /etc/cron.d
    #
    #     3. It runs the hourly files unconditionally
    #         - but if anacron is up and running ( by whatever means ) it will already do that
    #            so the same gating as we use on daily/weekly/monthly should also apply to hourly!!
    #

    if ${cronExtensionsWillRun}
    then
        # It isn't obvious which parts of the confused mess documented above need to be present
        #  to flag up that we are running 'dummy anacron'
        #
        # I'm going to detect just the invocation of cron.hourly. If the rest is malformed then hard luck.
        if cat "${mainCrontabAPAFN}" | grep -q "${anacronHourlyAPADN}"
        then
            # We are on one of the systems ( like DX2 / DX3 ) which dummy-up anacron in the main crontab.
            #
            runningDummyAnacron=true
            dummyAnacronUsesMainCrontab=true
        fi
    fi
fi

if ${runpartsEtcCronHourly}
then
    if ! ${quiet}
    then
        echo "Have detected that the system will run all tasks in /etc/cron.hourly."
    fi
fi

runningAnacronSomehow=false
if ${runningRealAnacron}
then
    runningAnacronSomehow=true

    if ! ${quiet}
    then
        echo "Have detected that the system is using 'real anacron'."
    fi
elif ${runningDummyAnacron}
then
    runningAnacronSomehow=true
    if ! ${quiet}
    then
        echo "Have detected that the system is using 'dummy anacron'."
    fi
else
    if ! ${quiet}
    then
        echo "Have detected that the system is not using anacron at all."
    fi
fi

# Single tab character.
tab=$(echo -en "\t")

# Given a stream of crontab lines:
#     replace whitespace characters with a single space
#     remove any spaces from the beginning of each line.
#     exclude non-cron job lines
#     replace '@monthly', 'Wed' and 'May' type of tokens with corresponding numeric sequences
#      so they can be processed by the rest of the code.
#     drop lines which do run-parts on /etc/cron.xxx     - there is special processing for them.
#
# Reads from stdin, and writes to stdout.
#  SO DO NOT INSERT SIMPLE ECHO STATEMENTS FOR DEBUGGING HERE!!
#   ( the debug statements in here write to stderr )
#
# @param  prefix                               A string to be prepended to each line we output.
# @param  skipHourlyAndDummyAnacronRunParts    true if lines which would do run-parts on /etc/cron.xxx directories are to be suppressed.
#                                               this now includes the 'hourly' one which we COULD process now if we wished
#                                               but choose to deal with later as a special case.
#
function cleanCronLines()
{
    local prefix="$1"                           ; shift
    local skipHourlyAndDummyAnacronRunParts="$1"; shift

    # @FIXME DGC 28-Jan-2019
    #           I think we should drop all leading whitespace - this just seems to do one.

    local setMatchMonthField='matchMonthField="s#^(((((\*|[0-9]+-[0-9]+|[0-9]+)(/[0-9]+)?|[0-9]+(,[0-9]+)+) *){3}) ${month} )#\2 ${monthNum} #I"'
    local setMatchDowField='  matchDowField="  s#^(((((\*|[0-9]+-[0-9]+|[0-9]+)(/[0-9]+)?|[0-9]+(,[0-9]+)+) *){4}) ${dow} )#\2 ${dowNum} #I"'

    while read line
    do
        if ${showProgress} ; then echo -n "c" 1>&2 ; fi

        #    sed "s/\s+/ /g"                convert all multiple-spaces to single space
        #    sed "s/^ //g"                  remove any number of leading whitespaces ( not tabs - should really )
        #
        #    grep
        #          --invert-match              emit only lines NOT matching the following pattern...
        #             ^(|||)                   match any of these alternatives, but only at start of line
        #             $                        blank line
        #             #                        comment       line     [ disregard leading whitespace. ]
        #             [[:alnum:]_]+=           <identifier>= line     [ disregard leading whitespace. ]
        #
        #    grep
        #     ignore lines like
        #        25 6 * * *    root    test -x /usr/sbin/anacron || ( cd / && run-parts --report /etc/cron.<period> )
        #
        #     ( we test for those separately. )
        #
        #    sed "s/^@xxxx/0 0 1 1 9/"      convert the conventional @xxx tags
        #                                    to roughly corresponding 'standard' timing settings.
        #                                    the '9' in reboot will be spotted later, and treated specially.
        #
        # In the following lines, each field can have one of the formats:
        #     \*                  meaning   *
        #     [0-9]+-[0-9]+       meaning   4-7
        #     [0-9]+              meaning   23
        #  each of which can have an optional /123 type divider appended.
        #     [0-9]+(,[0-9]+)*    meaning   2,8,12
        #
        #    sed "s/ ... Jan /... 1/I"
        #                                  convert month-of-year tokens ( in either case ) into numeric equivalents
        #    sed "s/ ... Mon /... 1/I"
        #                                  convert day-of-week tokens ( in either case ) into numeric equivalents
        #
        #    sed "s/ ... 0/... 7/"
        #                                  force Sunday to be represented by 7, not zero, as it helps during sorting later.
        #
        #    insert the required prefix.
        #

        # Skip the line completely if it is
        #     empty or comment
        #     crontab parameter setting
        #  line.

        local line

        line="$(echo "${line}"                     | \
                sed  -r    "s/\s+/ /g ; s/^ //g"   | \
                grep -E -v '^$|^#|[[:alnum:]_]+='    \
               )"

        if ${skipHourlyAndDummyAnacronRunParts}
        then
            # Skip the line completely if it is
            #     a dummy-anacron run-parts for daily/weekly/monthly
            #  line.
            # NOT INCLUDING THE 'hourly' one

            # This is the old version which did NOT skip the hourly line, because it has no 'test' section.
            # The test worked, but it's way more delicate that it needs to be:
            #     'anacron*.*run-parts.*/etc/cron' would be more than specific enough
            #
            #line="$(echo "${line}"                                                                         | \
            #        grep -E -v 'test *-x */usr/sbin/anacron *\|\| *\( *cd */ *&& *run-parts.*/etc/cron\.'    \
            #       )"

            # This is the new version which does skip the hourly line.
            #  We will have detected and flagged its existence earlier.
            #
            line="$(echo "${line}"                       | \
                    grep -E -v 'run-parts.*/etc/cron\.'    \
                   )"        
        fi

        if [ -z "${line}" ]
        then
            #if ${showProgress} ; then echo -n ">" 1>&2 ; fi

            continue
        fi

        if [ "@" = "${line:0:1}" ]
        then
            if ${showProgress} ; then echo -n "@" 1>&2 ; fi

            # In the 'special markers' for @reboot, avoid -99 as it is globally exchanged later.
            # Swap the abbreviated time-reporesentations for roughly equivalent numeric ones.
            #
            line="$(echo "${line}"                     |  \
                    sed -r "s/^@reboot/98 98 98 989 98/;  \
                            s/^@hourly/0 * * * */      ;  \
                            s/^@daily/0 0 * * */       ;  \
                            s/^@midnight/0 0 * * */    ;  \
                            s/^@weekly/0 0 * * 7/                       ;  \
                            s/^@monthly/0 0 1 * */     ;  \
                            s/^@annually/0 0 1 1 */    ;  \
                            s/^@yearly/0 0 1 1 */ "       \
                   )"
        fi

        if echo "${line}" | grep -qiE "Jan|Feb|Mar|Apr|May|Jun|Jly|Aug|Sep|Oct|Nov|Dec|Mon|Tue|Wed|Thu|Fri|Sat|Sun"
        then
            if ${showProgress} ; then echo -n "M" 1>&2 ; fi

            line="$(echo "${line}"                                                                           |  \
                    (month="Jan"; monthNum="1" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Feb"; monthNum="2" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Mar"; monthNum="3" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Apr"; monthNum="4" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="May"; monthNum="5" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Jun"; monthNum="6" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Jly"; monthNum="7" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Aug"; monthNum="8" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Sep"; monthNum="9" ; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Oct"; monthNum="10"; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Nov"; monthNum="11"; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (month="Dec"; monthNum="12"; eval "${setMatchMonthField}"; sed -r "${matchMonthField}")  |  \
                    (dow="Mon";   dowNum="1"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="Tue";   dowNum="2"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="Wed";   dowNum="3"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="Thu";   dowNum="4"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="Fri";   dowNum="5"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="Sat";   dowNum="6"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="Sun";   dowNum="7"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )  |  \
                    (dow="0";     dowNum="7"   ; eval "${setMatchDowField}"  ; sed -r "${matchDowField}"  )     \
                   )"
        fi

        # You could emit a trace character here to show something got through
        #  but as it happens all lines we pass on are processed by the routine below
        #  which will emit one for us.
        #
        echo "${prefix} | ${line}"
    done;
}

# Given a stream of cleaned crontab lines,
#  if they don't include the run-parts command
#      echo unchanged
#  if they do
#      show each executable file in the run-parts directory as if it were scheduled explicitly.
#
# Reads from stdin, and writes to stdout.
#  SO DO NOT INSERT SIMPLE ECHO STATEMENTS FOR DEBUGGING HERE!!
#   ( the debug statements in here write to stderr )
#
function lookupRunParts()
{
    while read line
    do
#echo "#running lookupRunParts on '${line}'"

        local match=$(echo "${line}" | grep -Eo 'run-parts (-{1,2}\S+ )*\S+' )

        if [ -z "${match}" ]
        then
            if ${showProgress} ; then echo -n "l" 1>&2 ; fi

            echo "${line}"
        else
            if ${showProgress} ; then echo -n "e" 1>&2 ; fi

            # This is awkward code - it needs to know how many fields there are on the line.
            # It would be better to split the line in two at the token "run-parts"
            #
            prefixCronAndUserFields=$(echo "${line}"  | cut -f1-8 -d' '  )
            cronJobDir=$(             echo "${match}" | awk '{print $NF}') 

#echo "#expanding run-parts in '${line}' with prefix cron and user fields '${prefixCronAndUserFields}'"

            if [ -d "${cronJobDir}" ]
            then
                # The following line will not report 'hidden files' and I assume the behavious of run-parts is the same,
                #  though I've made no attempt to check that.
                for cronJobAPAFN in "${cronJobDir}"/*
                do
                    #echo "Considering the run-parts file '${cronJobAPAFN}'" >&2

                    if  [ -f "${cronJobAPAFN}" ]
                    then
                        # NB - just because we have copied the cron job file to the output
                        #       does not mean that run-parts will execute it.
                        #       The file name must be simple, and in particular no . characters are allowed so .sh files WILL NOT RUN

                        echo -n "${prefixCronAndUserFields} "

                        if ! filenameWillBeProcessedByRunParts "${cronJobAPAFN}"
                        then
                            echo "RPBAD_${cronJobAPAFN}"
                        else
                            echo "${cronJobAPAFN}"
                        fi
                    fi
                done
            fi
        fi
    done
}

# Temporary files for crontab lines.
#
# The following lines must match the deletion lines in the function below.
#
# A better scheme which created them all in a subdirectory of /tmp,
#  and set an exit trap to remove the subdirectory and contents,
#  would be better.
#

if ${showProgress} ; then echo -n "1"; fi

keepWorkFiles=${runByAuthor}

if ${keepWorkFiles}
then
    nonVolatileShowCronJobsAPADN="/tmp/show-cron-jobs"

    mkdir -p "${nonVolatileShowCronJobsAPADN}/"

    # At one time these were split between /tmp itself, and the subdirectory, but I don't think there was a good reason.
    #
    cleanMainCrontabLinesAPAFN="${nonVolatileShowCronJobsAPADN}/cleanCronLines.txt"
    cronLinesAPAFN="${nonVolatileShowCronJobsAPADN}/dexdyne/cronLines.txt"
    cronForUserAPAFN="${nonVolatileShowCronJobsAPADN}/dexdyne/cronForUser.txt"
    sortedLinesAPAFN="${nonVolatileShowCronJobsAPADN}/sortedLines.txt"
    annotatedSortedLinesAPAFN="${nonVolatileShowCronJobsAPADN}/annotatedSortedLines.txt"
else
    # We just assume, and depend on, the presence and normal operation of mktemp.
    #
    # We assume that if it fails it will emit something helpful to stderr, so we don't need to.
    #
    cleanMainCrontabLinesAPAFN="$(mktemp)" || exit 1
    cronLinesAPAFN="$(mktemp)"             || exit 1
    cronForUserAPAFN="$(mktemp)"           || exit 1
    sortedLinesAPAFN="$(mktemp)"           || exit 1
    annotatedSortedLinesAPAFN="$(mktemp)"  || exit 1
fi

deleteTempFiles()
{
    # The following lines must match the creation lines above.
    # We run a delete on each of the files even if they were in fact never created.
    #
    rm -f "${cleanMainCrontabLinesAPAFN}"
    rm -f "${cronLinesAPAFN}"
    rm -f "${cronForUserAPAFN}"
    rm -f "${sortedLinesAPAFN}"
    rm -f "${annotatedSortedLinesAPAFN}"
}

if ${keepWorkFiles}
then
    # We will keep these after running, but we have no interest in any previous versions that may be lying about now.
    deleteTempFiles
else
    # Arrange to delete the temporary files on script exit.

    trap deleteTempFiles EXIT
fi

if ${showProgress} ; then echo -n "2"; fi

# Start with all of the jobs from the main crontab file,
#  except for the 4 supporting jobs for dummy-anacron.

# At this stage we don't want to process hourly tasks, or daily/weekly/monthly dummy-anacron ones.
pleaseSkipHourlyAndDummyAnacronRunParts=true

# I think the only reason we create the intermediate file is for debugging - logically it's not required.

cat "${mainCrontabAPAFN}"           | cleanCronLines "/etc/crontab" ${pleaseSkipHourlyAndDummyAnacronRunParts} >  "${cleanMainCrontabLinesAPAFN}"

# It would be unusual to find a run-parts line in the main crontab which was not associated with anacron
#  but we have the coding to deal with it if someone adds one, so do so.
#
cat "${cleanMainCrontabLinesAPAFN}" | lookupRunParts                                                           >  "${cronLinesAPAFN}"

if false
then
    echo "Main crontab file ( normally excluding dummy anacron lines ):"
    cat ${cronLinesAPAFN}  | sed "s#${tab}#<tab>#g"
    echo "-----------"
    echo
fi

if ${showProgress} ; then echo  "3"; fi

# Add all of the jobs from files in the system-wide cron.d directory, and user-specific crontabs.

if ${cronExtensionsWillRun}
then
    for cronDotDFileAPAFN in "${cronExtensionsMainAPADN}"/*
    do
        fileName="$(basename ${cronDotDFileAPAFN})"

        cat ${cronDotDFileAPAFN} | cleanCronLines "cron.d/${fileName}" | lookupRunParts >> "${cronLinesAPAFN}"
    done

    if ${showProgress} ; then echo  "4"; fi

    if false
    then
        echo "Main crontab file ( normally excluding dummy anacron lines ) and all cron.d files contain:"
        cat ${cronLinesAPAFN}  | sed "s#${tab}#<tab>#g"
        echo "-----------"
        echo
    fi

    # The following flags were configured earlier
    #     $runpartsEtcCronHourly
    #
    #   a  $runningRealAnacron
    #    b     $realAnacronUsesSystemdTimer
    #    b     $realAnacronUsesMainCrontab
    #    b     $realAnacronUsesHourlyAddition
    #   a  $runningDummyAnacron
    #    c     $dummyAnacronUsesMainCrontab=false
    #
    #      $runningAnacronSomehow           ( true if running real, or dummy )
    #
    # If the sets a, b and c, only one flag can be set.

    if ${showProgress} ; then echo  "5"; fi

    # Each user on the machine can have a crontab ( notably root, but others have been seen )
    #  go and locate any such and add their tasks to the list.

    # Get a list of users on this machine. Most of whom will never run a cron task.
    #
    declare -a users
    knownUsers=0

    while read user
    do
        users[${knownUsers}]="${user}"
        (( knownUsers++ ))

    done < <(cut --fields=1 --delimiter=: /etc/passwd)

    # This only works because user names cannot contain spaces or semicolons.
    #
    # sevUsers means "semicolon-encapulated-values"
    #  the list starts with, ends with, and is separated using, semicolons.
    #
    # bash does not have a proper 'does this entry exists in the array' function
    #  ( though you can test for an empty string if you aren't trapping undefined variables. )
    #  but we can grep for a user name in a long string of them.
    #
    sevUsers=";${users[@]};"; sevUsers="${sevUsers// /;}"

    # debug.
    #echo "sevUsers = '${sevUsers}'"

    if ${showProgress} ; then echo  "6"; fi

    # Examine each user's crontab (if it exists). Insert the user's name between the
    #  five time fields and the command, so the lines match the main crontab ones.

    checkUser=0

    while [ "${checkUser}" -lt "${knownUsers}" ]
    do
        user="${users[${checkUser}]}"

        # Note that this edit will fail on a malformed line.
        # We have to make sure we don't create double-spaces, as that messes up line splitting
        #  but ensuring that results in awkward-looking code.
        #
        crontab -l -u "${user}" 2>/dev/null                            | \
            cleanCronLines  "/var/spool/.../${user}"                   | \
            sed -r "s/^(\S+) \| ((\S+ +){5})(.+)$/\1 | \2${user} \4/"  | \
            lookupRunParts                                               \
                > ${cronForUserAPAFN}

        while IFS= read -r cronLine
        do
            echo "${cronLine}"          >> "${cronLinesAPAFN}"
        done < ${cronForUserAPAFN}

        (( checkUser++ ))

    done

    if ${showProgress} ; then echo  "7"; fi

    if false
    then
        echo "Main crontab file ( normally excluding dummy anacron lines ) and all cron.d files and any user crontabs contain:"
        cat ${cronLinesAPAFN} | sed "s#${tab}#<tab>#g"
        echo "-----------"
        echo
    fi
fi

# You could take the view that anacron cannot possibly run on top of a cron that doesn't support cron.d,
#  but it's just vaguely possible that could be false,
#  so we leave the following code OUTSIDE the above 'if' block, and go through the motions.

# The cron.hourly directory commonly contains just the single crontab file for anacron itself,
#  but if other things appear there, we should deal with them.

if $runpartsEtcCronHourly
then
    # The read command will return success if any output is produced by 'find',
    #  the find command itself does NOT flag whether it found anything.
    # Also note that it finds hidden files - which we then have to discard at the next stage of processing.
    #
    if find "${anacronHourlyAPARN}" -mindepth 1 -type f | read
    then
        # This will ignore README files even if they will be executed - tant pis.
        # Exclude the expected file to run anacron itself - though it would be harmless not to.
        #
        for fileName in $(ls -a "${anacronHourlyAPARN}" | grep -Ev "\.placeholder$|\.$|\.\.$|README|0anacron")
        do
            # @FIXME DGC 7-Jan-2021
            #           THIS ISN'T RIGHT
            #           The timing of the hourly servicing actually comes from 
            #             either /etc/cron.d/0hourly
            #                 which on the cummins server was:
            #                     01 * * * * root run-parts /etc/cron.hourly
            #                 so 1-minute past.
            #             or /etc/crontab
            #                 which on a DX2 was:
            #                     17 *    * * *   root    cd / && run-parts --report /etc/cron.hourly
            #           A complete implementation would pick up that timing and insert it here.

            anacronTiming="at-same-min-each-hour"

            wontRunTag=""
            if ! filenameWillBeProcessedByRunParts "${fileName}"
            then
                wontRunTag="RPBAD_"
            fi

            # Note these timing parameters are not EXACTLY what anacron
            #  does with such 'daily' tasks, but they are an approximately equivalent stand-in.
            #
            echo  "${anacronHourlyAPARN} | 98 * * -99%${anacronTiming}% * root ${wontRunTag}${anacronHourlyAPARN}${fileName}"  >> "${cronLinesAPAFN}"
        done
    fi

    if false
    then
        echo "Main crontab file ( normally excluding dummy anacron lines ) and all cron.d files and any user crontabs, plus hourly dir contain:"
        cat ${cronLinesAPAFN} | sed "s#${tab}#<tab>#g"
        echo "-----------"
        echo
    fi
fi

# The following section simply assumes that no-one has altered the standard /etc/anacrontab file
#  We do not completely deal with the
#      START_HOURS_RANGE
#   and
#      RANDOM_DELAY
#   parameters.
#  However we do now carry them through, and print them rather cryptically on the output.
#
# I think each task can set a further timing setting ( called 'base delay' below )
#  which we have not read up about, and completely ignore.
#
# Use of the START_HOURS_RANGE setting
#  makes the assumption that jobs run under this system are limited to 'regular housekeeping'
#  tasks which it is reasonable to suppress or put-off-till-later during certain periods of the day.
#
# That file on a server we looked at read:
#
#    # /etc/anacrontab: configuration file for anacron
#
#    # See anacron(8) and anacrontab(5) for details.
#
#    SHELL=/bin/sh
#    PATH=/sbin:/bin:/usr/sbin:/usr/bin
#    MAILTO=root
#    # the maximal random delay added to the base delay of the jobs
#    RANDOM_DELAY=45
#    # the jobs will be started during the following hours only
#    START_HOURS_RANGE=3-22
#
#    #period in days   delay in minutes   job-identifier   command
#    1                 5                  cron.daily       nice run-parts /etc/cron.daily
#    7                 25                 cron.weekly      nice run-parts /etc/cron.weekly
#    @monthly          45                 cron.monthly     nice run-parts /etc/cron.monthly
#

if ${runningAnacronSomehow}
then
    # These settings can legitimately be absent.

    if ${runningDummyAnacron}
    then
        anacronPrefix="dummy-anacron"
    else
        # Running real anacron - pick out some of the configurations it uses.
        #
        rangeSetting="$(cat "${anacrontabAPAFN}" | grep "START_HOURS_RANGE" | sed 's/START_HOURS_RANGE=//')"
        delaySetting="$(cat "${anacrontabAPAFN}" | grep "RANDOM_DELAY"      | sed 's/RANDOM_DELAY=//'     )"

        # If we have, for instance:
        #     RANDOM_DELAY=45
        #     START_HOURS_RANGE=3-22
        #  we create for the delay on 'daily' tasks the string:
        #     anacron_3-22[+5-50]
        #  and show it in the timing information we output.
        #
        # NB - we are completely failing to read and add-in the base delay for each task!!!!!
        #
        assumedAnacronBaseDelayDaily=5
        assumedAnacronBaseDelayWeekly=25
        assumedAnacronBaseDelayMonthly=45

        anacronTiming="anacron"
        if [ -n "${rangeSetting}" ]
        then
            anacronTiming="${anacronTiming}@${rangeSetting/-/..}"
        fi

        anacronDelaySettingMinDaily=$assumedAnacronBaseDelayDaily
        anacronDelaySettingMinWeekly=$assumedAnacronBaseDelayWeekly
        anacronDelaySettingMinMonthly=$assumedAnacronBaseDelayMonthly

        anacronTimingDaily="${anacronTiming}:${anacronDelaySettingMinDaily}"
        anacronTimingWeekly="${anacronTiming}:${anacronDelaySettingMinWeekly}"
        anacronTimingMonthly="${anacronTiming}:${anacronDelaySettingMinMonthly}"

        if [ -n "${delaySetting}" ]
        then
            anacronDelaySettingMaxDaily=$((  anacronDelaySettingMinDaily   + delaySetting))
            anacronDelaySettingMaxWeekly=$(( anacronDelaySettingMinWeekly  + delaySetting))
            anacronDelaySettingMaxMonthly=$((anacronDelaySettingMinMonthly + delaySetting))

            anacronTimingDaily="${anacronTimingDaily}~${anacronDelaySettingMaxDaily}"
            anacronTimingWeekly="${anacronTimingDaily}~${anacronDelaySettingMaxWeekly}"
            anacronTimingMonthly="${anacronTimingDaily}~${anacronDelaySettingMaxMonthly}"
        fi

        # trailing text suspended.
        #anacronTimingDaily="${anacronTimingDaily}"
        #anacronTimingWeekly="${anacronTimingDaily}"
        #anacronTimingMonthly="${anacronTimingDaily}"
    fi

    # The following code inserts impossible value strings including '98',
    #  which will sort anacron tasks after non-anacron tasks
    #  in the task list we print out.
    # ( you could try using -1 to sort them 'before'. )
    #
    # We expect to spot those impossible values and replace them in the final output.

    # In a non-systemd unit, apparently anacron is only run daily.
    #  ( which of course is good enough to run it's sub-tasks daily/weekly/monthly )
    #
    # In a systemd machine it is run hourly. See:
    #     https://unix.stackexchange.com/questions/478803/is-it-true-that-cron-daily-runs-anacron-everyhour
    #
    # However even if run hourly it does not take control of other tasks in /etc/cron.hourly.

    # Apparently all anacron tasks run as root.

    # The logic here DOES NOT examine whether the things it finds are executable.
    # If we were simply building a list of things which WILL happen, we could add
    #  -executable                                to the find command.
    #  [ "x" = "$( ls -l $file | cut -c4-4 ) ]    before we echo the lines to $cronLinesAPAFN
    #
    # HOWEVER - one of the features of this script is that it brings to your attention
    #            anything which WOULD have run, if only the executable flag was set
    #             - but won't because it isn't.
    #
    # So we ignore the executable status here, and add it to the list regardless.

    # I find that ( on the DX3 at least ) some files named .placeholder exist,
    #  and they contain the text 'This file is a simple placeholder to keep dpkg from removing this directory'
    #  we need to ignore any such files - they are not anacron tasks

    if [ -d "${anacronDailyAPARN}" ]                                                        # Should always be true, but cover ourselves
    then
        # The read command will return success if any output is produced by 'find',
        #  the find command itself does NOT flag whether it found anything.
        #
        if find "${anacronDailyAPARN}" -mindepth 1 -type f | read
        then
            # This will ignore README files even if they will be executed - tant pis.
            #
            for fileName in $(ls -a "${anacronDailyAPARN}" | grep -Ev "\.placeholder$|\.$|\.\.$|README")
            do
                wontRunTag=""
                if ! filenameWillBeProcessedByRunParts "${fileName}"
                then
                    wontRunTag="RPBAD_"
                fi

                # Note these timing parameters are not EXACTLY what anacron
                #  does with such 'daily' tasks, but they are an approximately equivalent stand-in.
                #
                echo  "${anacronDailyAPARN} | 0 0 * -99%${anacronTimingDaily}% * root ${wontRunTag}${anacronDailyAPARN}${fileName}"  >> "${cronLinesAPAFN}"
            done
        fi
    fi

    if false
    then
        echo "Main crontab file ( normally excluding dummy anacron lines ) and all cron.d files and any user crontabs, plus hourly+daily dir contain:"
        cat ${cronLinesAPAFN} | sed "s#${tab}#<tab>#g"
        echo "-----------"
        echo
    fi

    if [ -d "${anacronWeeklyAPARN}" ]                                                     # Should always be true, but cover ourselves
    then
        # See comment above.
        if find "${anacronWeeklyAPARN}" -mindepth 1 -type f | read
        then
            # This will ignore README files even if they will be executed - tant pis.
            #
            for fileName in $(ls -a "${anacronWeeklyAPARN}" | grep -Ev "\.placeholder$|\.$|\.\.$|README")
            do
                wontRunTag=""
                if ! filenameWillBeProcessedByRunParts "${fileName}"
                then
                    wontRunTag="RPBAD_"
                fi

                # Note these timing parameters are not EXACTLY what anacron
                #  does with such 'weekly' tasks, but they are an approximately equivalent stand-in.
                #
                echo  "${anacronWeeklyAPARN} | 0 0 * -99%${anacronTimingWeekly}% 0 root ${wontRunTag}${anacronWeeklyAPARN}${fileName}"  >> "${cronLinesAPAFN}"
            done
        fi
    fi

    if [ -d "${anacronMonthlyAPARN}" ]                                                    # Should always be true, but cover ourselves
    then
        # See comment above.
        if find "${anacronMonthlyAPARN}" -mindepth 1 -type f | read
        then
            # This will ignore README files even if they will be executed - tant pis.
            #
            for fileName in $(ls -a "${anacronMonthlyAPARN}" | grep -Ev "\.placeholder$|\.$|\.\.$|README")
            do
                wontRunTag=""
                if ! filenameWillBeProcessedByRunParts "${fileName}"
                then
                    wontRunTag="RPBAD_"
                fi

                # Note these timing parameters are not EXACTLY what anacron
                #  does with such 'monthly' tasks, but they are an approximately equivalent stand-in.
                #
                echo  "${anacronMonthlyAPARN} | 0 0 35 -99%${anacronTimingMonthly}% * root ${wontRunTag}${anacronMonthlyAPARN}${fileName}"  >> "${cronLinesAPAFN}"
            done
        fi
    fi
fi

if ${showProgress} ; then echo  "8"; fi

if false
then
    echo "All cron lines from all sources:"
    cat ${cronLinesAPAFN} | sed "s#${tab}#<tab>#g"
    echo "-----------"
    echo
fi

#
# cron lines consist of six fields with predictable formats, followed by a command line with optional embedded spaces.
#
# Output the collected crontab lines.
#  Replace the single spaces between the 6 fields with tab characters.
#  Sort the lines by hour and minute.
#  Insert the header line.
#  Format the results as a table.
#
#example:
#    root-crontab | 10 1 * * * /usr/local/sbin/hostmaker.rb fred george

tabbedLines=$(cat "${cronLinesAPAFN}"                                                                                           | \
              sed  -r "s/^(\S+) \| (\S+) +(\S+) +(\S+) +(\S+) +(\S+) +(\S+) +(\S+) *(.*)$/\1\t|\t\2\t\3\t\4\t\5\t\6\t\7\t\8 \9/"   \
             )

if false
then
    echo "(unsorted) tabbedLines ="
    echo "${tabbedLines}" | sed "s#${tab}#<tab>#g"
    echo "-------------------"
fi

if ${showProgress} ; then echo  "9"; fi

# Replace asterisk values with 99 - which is normally bigger than any legal value
#
# Typical lines to be sorted ( spaces added for alignment only ):
#
#      1                     2  3     4   5   6                          7
#                                                                        |________ dow
#                                             |___________________________________ month
#                                         |_______________________________________ dom
#                                     |___________________________________________ hour
#                               |_________________________________________________ minute
#                               |     |   |   |                          |
# /var/spool/.../postgres    |  10    -99 -99 -99                        -99  postgres    /home/Scripts/vpn-timing.sh > /tmp/dexdyne/cron/vpn-timing-info/$(whoami)---last-vpn-timing.stdout.txt 2>&1
#
# /etc/cron.weekly/          |  0     0   -99 -99%anacron_3-22[~45]%     0    root        /etc/cron.weekly/dummyWeeklyTask
# /var/spool/.../root        |  5     5   1   -99                        -99  root        /etc/dexdyne/reports/cummins/cummins-generator-report-belgium-month-run.sh

#
# We expect to spot those impossible values and replace them in the final output
#  usually with a meaningful word like 'weekly' but failing that, back to asterisk.
#
# It may be logically impossible to get the sort 'perfect'
#  My desired order would be:
#     every minute
#     every few minutes
#     hourly                  at mm minutes past, in order of xxx
#     daily                   at time hh:mm,      in order of hh:mm
#     on day n of week,       at time hh:mm,      in order of day, then hh:mm
#     on day n of each month, at time hh:mm,      in order of day, then hh:mm
#      we do not really encounter stuff for "run on the 3rd of December only" so I don't know how well it works
#     @reboot
#
#   day-of-week and day-of-month are really parallel and equivalent sub-systems, with no obvious precendence between them
#    I choose to work up in interval size, so week-related comes first.
#
#  I think I'm there.
#
# The method use here is horrific, and heuristic.
#    ATTOW we sort by
#       month        column - which is borrowed to get @:reboot to sort absolutely last
#       day-of-month column - which only holds a value for 'day-of-month related' entries - which is why they currently sort late
#       day-of-week  column - which only holds a value for 'day-of-week  related' entries - which is why they currently sort lateish
#       hour         column
#       minute       column
#   the general principle is that specifying a value sorts the entry later than leaving it as a wildcard.

# @FIXME DGC 20-Jan-2022
#           This isn't quite working. Here is some output when run on a 3003 unit:
#               executable              | /etc/crontab        | every minute                root  /etc/dexdyne/root-cron-scripts/every-minute/every-minute-test-root-cron
#               executable              | /etc/crontab        | every 5 minutes             root  /etc/dexdyne/root-cron-scripts/every-five-minutes/every-five-minutes-test-root-cron
#               executable              | /var/spool/.../root | every minute                root  /etc/cron/root/every-minute/test-cron
#               BAD RUN-PARTS FILENAME  | /var/spool/.../root | every minute                root  /etc/cron/root/every-minute/test-cron-needs-symlink.sh
#               executable              | /etc/crontab        | hourly at 1 mins past       root  /etc/dexdyne/root-cron-scripts/hourly/hourly-test-root-cron
#
#           The 'every-5-minutes' line should have ended up below all the 'every minute' ones.
#

echo "${tabbedLines}"                                 | \
   sed  -r "s#\t\*#\t-99#g"                           | \
   sed  -r "s#-99/#-98/#g"                            | \
   sort -t"${tab}" -k6,6n -k5,5n -k7,7n -k4,4n -k3,3n | \
   sed  -r "s#-98/#-99/#g"                            | \
   sed  -r "s/\t-99/\t\*/g"                             \
       > ${sortedLinesAPAFN}

if false
then
    echo ------------------------------1--------------------------

    echo "${tabbedLines}"                                 | \
       sed  -r "s/\t\*/\t-99/g"                           | \
       sed  -r "s#-99/#-98/#g"                            | \
       column -t

    echo ------------------------------2--------------------------

    echo "${tabbedLines}"                                 | \
       sed  -r "s/\t\*/\t-99/g"                           | \
       sed  -r "s#-99/#-98/#g"                            | \
       sort -t"${tab}" -k6,6n                             | \
       column -t

    echo ------------------------------2--------------------------

    echo "${tabbedLines}"                                 | \
       sed  -r "s/\t\*/\t-99/g"                           | \
       sed  -r "s#-99/#-98/#g"                            | \
       sort -t"${tab}" -k6,6n -k5,5n                      | \
       column -t

    echo ------------------------------3--------------------------

    echo "${tabbedLines}"                                 | \
       sed  -r "s/\t\*/\t-99/g"                           | \
       sed  -r "s#-99/#-98/#g"                            | \
       sort -t"${tab}" -k6,6n -k5,5n -k7,7n -k4,4n -k3,3n | \
       column -t

    echo "Sorted lines ="
    cat "${sortedLinesAPAFN}"  | sed "s#${tab}#___#g"
    echo "-------------------"
fi

#echo "users and executables="
#cat "${sortedLinesAPAFN}" | cut -d"$tab" -f 8- | cut -d' ' -f1-2  | sed "s#${tab}#<tab>#g"
#echo "-------------------"

if ${showProgress} ; then echo  "A"; fi

: > ${annotatedSortedLinesAPAFN}


sysstatEnabledIsKnown=false
if [ -f "/etc/default/sysstat" ]
then :
    sysstatEnabledIsKnown=true
    sysstatsAreEnabled=false

    # Strictly we should also test for ="false" but assume the file is well-formed
    #
    if cat "/etc/default/sysstat" | grep -q 'ENABLED="true"'
    then :
        sysstatsAreEnabled=true
    fi
fi

ntpStatsEnabledIsKnown=false
if [ -f "/etc/ntp.conf" ]
then :
    ntpStatsEnabledIsKnown=true
    ntpStatsAreEnabled=false

    # Strictly we should also test for ="false" but assume the file is well-formed
    #
    if cat "/etc/ntp.conf" | grep -v '^#' | grep -q " *statsdir "
    then :
        ntpStatsAreEnabled=true
    fi
fi

aptitudePkgstatesExists=false
if [ -f "/var/lib/aptitude/pkgstates" ]
then :
    aptitudePkgstatesExists=true
fi

# Strictly we should also test for ="false" but assume the file is well-formed
#
bsdmainutilsAreEnabled=false
if   [ -f "/etc/default/bsdmainutils" ]                                         \
  && [ -x "/usr/sbin/sendmail"        ]                                         \
  && [ -x "/usr/bin/cpp"              ]                                         \
  && cat "/etc/default/bsdmainutils" | grep -v '^#' | grep -q "RUN_DAILY=true"
then :
    bsdmainutilsAreEnabled=true
fi

while read sortedLine
do
    user=$(               echo -e "${sortedLine}" | cut -d"$tab" -f 8                   )
    executable=$(         echo -e "${sortedLine}" | cut -d"$tab" -f 9    | cut -d' ' -f1)
    executableAndParams=$(echo -e "${sortedLine}" | cut -d"$tab" -f 9-99                )

if false
then
    echo
    echo "'${sevUsers}'"                # semicolon encapsulated users.
    echo "';${user};'"
    echo "';${executable};'"
    echo "';${executableAndParams};'"
    echo

    continue
fi

tracing=false

#if echo ${executableAndParams} | grep -q "sa1"
#then :
#    tracing=true
#    set -x
#fi

    # We will label the lines 'MALFORMED' so they shouldn't be missed,
    #  the moans here are suppressed by the 'quiet' flag.

    executableTag=""

    if [ -z "${executable}" ]
    then
        if ! ${quiet}
        then
            echo
            echo "ERROR!!!!! A cron entry is malformed - probably too few fields - making it seem to have no executable command."
            echo "The line was ( similar to ): '${sortedLine}'"
            echo
         fi

        executableTag="MALFORMED\t"

    elif [ "${user}" = "*" ]
    then
        if ! ${quiet}
        then
            echo "ERROR!!!!! A cron entry is malformed - probably too many fields - making it seem to use a user of star."
            echo "The line was ( similar to ): '${sortedLine}'"
            echo
        fi

        executableTag="MALFORMED\t"

    elif [[ ! "${sevUsers}" =~ ";${user};" ]]    # See if ;<user>;  is anywhere in the list of known users.
    then
        if ! ${quiet}
        then
            echo
            echo "ERROR!!!!! User '${user}' given in a cron entry is not a known user on this machine."
            echo "The line was ( similar to ): '${sortedLine}'"
            echo
        fi

        executableTag="MALFORMED\t"

    elif   ${ntpStatsEnabledIsKnown}                          \
        && echo "${executableAndParams}" | grep -qE "\/ntp$"
    then :
        if ${ntpStatsAreEnabled}
        then :
            executableTag="NTP STATS ARE ENABLED\t"
        else :;:
            executableTag="NTP STATS ARE DISABLED\t"
        fi

    elif   ${sysstatEnabledIsKnown}                                          \
        && echo "${executableAndParams}" | grep -qE "debian-sa1|\/sysstat$"
    then :
        if ${sysstatsAreEnabled}
        then :
            executableTag="SYSSTAT IS ENABLED\t"
        else :;:
            executableTag="SYSSTAT IS DISABLED\t"
        fi

    elif   echo "${executableAndParams}" | grep -qE "\/aptitude$"  \
        && ! ${aptitudePkgstatesExists}
    then :
        executableTag="PKG STATES MISSING\t"

    elif  echo "${executableAndParams}" | grep -qE "\/bsdmainutils$"  \
        && ! ${bsdmainutilsAreEnabled}
    then :
        executableTag="BSD UTILS DISABLED\t"

    elif [ "/" = "${executable:0:1}" ] 
    then
        executableAPAFN="${executable}"

        # @FIXME DGC 18-Feb-2019
        #           This does not make use of the PATH= directive in the file,
        #            so will currently wrongly fail if one is utilised.

        if [ -f "${executableAPAFN}" ]
        then
            # See comment at the top of the file about how we would like to know if $user can execute this
            #  but testing that is too difficult to try here.
            #
            if [ -x "${executableAPAFN}" ]
            then
                executableTag="executable\t"
            else
                executableTag="NOT EXECUTABLE\t"
            fi
        else
            executableTag="MISSING    !!!\t"
        fi
    elif [ "RPBAD" = "${executable:0:5}" ] 
    then
        executableTag="BAD RUN-PARTS FILENAME\t"
    else
        # We have so far noticed two 'encapsulated commands' in crontab files,
        #  which we previously did not have logic to handle,
        #  but now have a go at.
        #
        # Of course any old bash command could be placed in a crontab command.
        #
        # If a command starts with a name that can be 'located'
        #  by the 'which' command, ( as all non-built-in commands will do )
        #  it is not currently considered a special case.
        #  This script will report itself 'happy' as the executable can be found.
        #
        # Built-in commands like 'if', '[' and 'command' cannot be 'located' by 'which'
        #  and if we do not detect them and treat them specially, they will be labelled as 'missing'
        #   - which of course they aren't.
        #
        # However in the case of the two we have encountered they are simply 'encapulating'
        #  some actual command which is to be used, and it is that command which we
        #  would like to tell the user of this script about.
        #
        # One takes the form
        #     [ -x fred ] && fred <params>
        #  the other
        #     command -v fred <params>
        #
        # For the first of these we now remove the [ ... ] && section
        #  and allow our later code to examine and label fred as missing or non-executable, in the normal way.
        #
        # For the second of these we simply ignore the 'command [-v]' part as if it weren't there.
        #
        # Similar-but-not-identical situations will be labelled as 'not analysed'.

        # The following line is not very sophisticated in what it matches - we could do better.
        executableAndParams="$(echo "${executableAndParams}" | sed -r "s#\[ \-x .* \] && ##" )"

        # We should probably tolerate this without the -v, but we don't at present.

        # This is 'interesting' - it doesn't actually locate the 'command' which will be executed -it converts
        #     command -v debian-sa1 > /dev/null && debian-sa1 1 1
        #  into
        #     debian-sa1 > /dev/null && debian-sa1 1 1
        #  and used the first token on the line as the command
        # which is 'adeqaute' to find the command the thing wants to execute
        #  PROVIDED the line sticks to the pattern
        #     command -v <whatever> > /dev/null && <whatever> <params maybe>
        # which apparently they all do.
        #
        executableAndParams="$(echo "${executableAndParams}" | sed -r "s#command -v ##" )"

        executable="$(         echo "${executableAndParams}" | cut -d' ' -f1)"

        #echo -n "LAST-DITCH - '${executable}' '${executable:0:1}' '${executable:0:2}' '${executable:0:7}'  -> "

        #
        # @param  executableAPAFN   is implicit
        #
        testExecutable()
        {
            if [ -f "${executableAPAFN}" ]
            then
                # See comment at the top of the file about how we would like to know if $user can execute this
                #  but testing that is too difficult to try here.
                #
                if [ -x "${executableAPAFN}" ]
                then
                    #echo "+x"
                    executableTag="executable\t"
                else
                    #echo "-x"
                    executableTag="NOT EXECUTABLE\t"
                fi
            else
                #echo "not found"
                executableTag="MISSING    !!!\t"
            fi
        }

        # We will just pragmatically expand this test to cover other built-in commands
        #  if we encounter other variations.
        #
        #     compgen-b
        #  will give you a useful list of built-in commands, if we have it.
        #
        #  On our servers that includes:
        #     .  ..
        #     [  test            but not [[ or if
        #     cd
        #     command
        #     echo
        #     false true
        #     set
        #  among many more
        #

        # look to match
        #     [ "Fri"              =   "$(/bin/date +%a)" ] && vacuum-index-values-and-alarms.php > /tmp/$(whoami)-vacuum-index-values-and-alarms-output.stdout.txt
        #     [ "$(/bin/date +%a)" =   "Fri"              ] && vacuum-index-values-and-alarms.php > /tmp/$(whoami)-vacuum-index-values-and-alarms-output.stdout.txt
        #     [ "$(/bin/date +%u)" -eq "5"                ] && vacuum-index-values-and-alarms.php > /tmp/$(whoami)-vacuum-index-values-and-alarms-output.stdout.txt
        #     [ "5"                -eq "$(/bin/date +%u)" ] && vacuum-index-values-and-alarms.php > /tmp/$(whoami)-vacuum-index-values-and-alarms-output.stdout.txt

        patText1='^ *\[ *["|'"'"']?...["|'"'"']? *= *(")?\$\( *(/bin/)?date *\+%a *\)(")? *\] * &&'         # Match textual first xxx of month tests.
        patNumb1='^ *\[ *["|'"'"']?[0-7]["|'"'"']? *\-eq *(")?\$\( *(/bin/)?date *\+%u *\)(")? *\] * &&'    # Match numeric first xxx of month tests.
        patText2='^ *\[ *(")?\$\( *(/bin/)?date *\+%a *\)(")? *= *["|'"'"']?...["|'"'"']? *\] * &&'         # Match textual first xxx of month tests.
        patNumb2='^ *\[ *(")?\$\( *(/bin/)?date *\+%u *\)(")? *\-eq *["|'"'"']?[0-7]["|'"'"']? *\] * &&'    # Match numeric first xxx of month tests.

#echo "<"${executableAndParams}">"

        if  [ -z "${executableTag}" ]
        then :
            if   [[ "${executableAndParams}" =~ $patText1 ]]  \
              || [[ "${executableAndParams}" =~ $patNumb1 ]]  \
              || [[ "${executableAndParams}" =~ $patText2 ]]  \
              || [[ "${executableAndParams}" =~ $patNumb2 ]]
            then
                executableAPAFN="${executableAndParams#*&& }"
                executableAPAFN="${executableAPAFN%% > *}"

#echo "yup <${executableAPAFN}>"

                 testExecutable

            elif   [ "["       = "${executable:0:1}" ] \
                || [ "test"    = "${executable:0:4}" ] \
                || [ "if"      = "${executable:0:2}" ] \
                || [ "command" = "${executable:0:7}" ]
            then
                #echo "skip"
                executableTag="can't analyse\t"
            elif [ "/" = "${executable:0:1}" ] 
            then
                executableAPAFN="${executable}"

                testExecutable

            elif which ${executable} > /dev/nul 2>&1
            then
                #echo "witchy"
                executableTag="on default path\t"
            else
                #echo "cant find"
                executableTag="?on some custom path?\t"
            fi
        fi
    fi

#    echo "${executableTag} '${sortedLine}'"

    # If we tagged a line with 'RPBAD_' we can remove it now. Bit clumsy code but it works.
    sortedLine="${sortedLine//RPBAD_}"

    echo "${annotatedSortedLines}${executableTag}| ${sortedLine}" >> ${annotatedSortedLinesAPAFN}

if ${tracing}
then :
    tracing=false
    set +x
    echo "^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^"
fi


done < ${sortedLinesAPAFN}

#echo "annotatedSortedLines ="
#cat "${annotatedSortedLinesAPAFN}" | sed "s#${tab}#<tab>#g"
#echo "-------------------"

if ${showProgress} ; then echo  "B"; fi

# We treat a repeat at any number of minutes past the hour as 'hourly' for our purposes.

# OBSOLTE COMMENT --- These lines convert
#     executable      | anacron_3-22[~45]   | daily at 98:98                         root        /etc/cron.daily/logrotate
#  into
#     executable      | anacron_3-22[~45]   | daily                                  root        /etc/cron.daily/logrotate
#
# It would be more sophisticated to convert them to
#     executable      | anacron             | daily < 45 mins after 03:00            root        /etc/cron.daily/logrotate

# Remove all leading zeroes on numbers
# Substitute human-readable versions of common numeric sequences.

# It is much faster to give sed 50 things to do than to load-and-run sed 50 times. Though it does look clunky.
#
sortedLinesTranslated=$(cat "${annotatedSortedLinesAPAFN}"                                                                                   |    \
                        sed -r "s# 0([0-9])# \1#g                                                                                              ;  \
                                s#\t0([0-9])#\t\1#g                                                                                            ;  \
                                s#-0([0-9])#-\1#g                                                                                              ;  \
                                s#,0([0-9])#,\1#g                                                                                              ;  \
                                                                                                                                                  \
                                s#\|\t98\t98\t98\t989\t98#|\t@reboot\t \t \t \t #g                                                             ;  \
                                                                                                                                                  \
                                s#\|\t\*\/1\t\*\t\*\t\*\t\*#|\tevery minute\t \t \t \t #g                                                      ;  \
                                s#\|\t\*\t\*\t\*\t\*\t\*#|\teach minute\t \t \t \t #g                                                          ;  \
                                s#\|\t\*\/([0-9]*)\t\*\t\*\t\*\t\*#|\tevery \1 minutes\t \t \t \t #g                                           ;  \
                                                                                                                                                  \
                                s#\|\t0\t\*\t\*\t\*\t\*#|\ton the hour\t \t \t \t #g                                                           ;  \
                                s#\|\t([0-9][0-9]?)\t\*\t\*\t\*\t\*#|\thourly at \1 mins past\t \t \t \t #g                                    ;  \
                                s#\|\t\0\t\*\/([0-9]*)\t\*\t\*\t\*#|\ton the hour every \1 hours\t \t \t \t #g                                 ;  \
                                                                                                                                                  \
                                s#\|\t98\t\*\t\*\t\*%(.*)%\t\*#|\t\1\t \t \t \t #g                                                             ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t\*\t\*\t\*#|\t@start of each day\t \t \t \t #g                                                     ;  \
                                                                                                                                                  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t\*#|\tdaily at \2:\1\t \t \t \t #g                                           ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t\*\t\*%(.*)%\t\*#|\t\1\t \t \t \t #g                                                               ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t\*\t\*\t1,2,3,4,5#|\tstart of each weekday\t \t \t \t \t#g                                         ;  \
                                s#\|\t0\t0\t\*\t\*\t1\t#|\tstart of each Monday\t \t \t \t \t#g                                                ;  \
                                s#\|\t0\t0\t\*\t\*\t2\t#|\tstart of each Tuesday\t \t \t \t \t#g                                               ;  \
                                s#\|\t0\t0\t\*\t\*\t3\t#|\tstart of each Wednesday\t \t \t \t \t#g                                             ;  \
                                s#\|\t0\t0\t\*\t\*\t4\t#|\tstart of each Thursday\t \t \t \t \t#g                                              ;  \
                                s#\|\t0\t0\t\*\t\*\t5\t#|\tstart of each Friday\t \t \t \t \t#g                                                ;  \
                                s#\|\t0\t0\t\*\t\*\t6\t#|\tstart of each Saturday\t \t \t \t \t#g                                              ;  \
                                s#\|\t0\t0\t\*\t\*\t7\t#|\tstart of each Sunday\t \t \t \t \t#g                                                ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Sun\"?)#|\tfirst Sunday of month at \2:\1\t \t \t \t \t\3#g      ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Mon\"?)#|\tfirst Monday of month at \2:\1\t \t \t \t \t\3#g      ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Tue\"?)#|\tfirst Tuesday of month at \2:\1\t \t \t \t \t\3#g     ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Wed\"?)#|\tfirst Wednesday of month at \2:\1\t \t \t \t \t\3#g   ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Thu\"?)#|\tfirst Thursday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Fri\"?)#|\tfirst Friday of month at \2:\1\t \t \t \t \t\3#g      ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* = *\"?Sat\"?)#|\tfirst Saturday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Sun\"? *= .*)#|\tfirst Sunday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Mon\"? *= .*)#|\tfirst Monday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Tue\"? *= .*)#|\tfirst Tuesday of month at \2:\1\t \t \t \t \t\3#g   ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Wed\"? *= .*)#|\tfirst Wednesday of month at \2:\1\t \t \t \t \t\3#g ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Thu\"? *= .*)#|\tfirst Thursday of month at \2:\1\t \t \t \t \t\3#g  ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Fri\"? *= .*)#|\tfirst Friday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?Sat\"? *= .*)#|\tfirst Saturday of month at \2:\1\t \t \t \t \t\3#g  ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?0\"?)#|\tfirst Sunday of month at \2:\1\t \t \t \t \t\3#g       ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?1\"?)#|\tfirst Monday of month at \2:\1\t \t \t \t \t\3#g       ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?2\"?)#|\tfirst Tuesday of month at \2:\1\t \t \t \t \t\3#g      ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?3\"?)#|\tfirst Wednesday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?4\"?)#|\tfirst Thursday of month at \2:\1\t \t \t \t \t\3#g     ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?5\"?)#|\tfirst Friday of month at \2:\1\t \t \t \t \t\3#g       ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?6\"?)#|\tfirst Saturday of month at \2:\1\t \t \t \t \t\3#g     ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.* -eq \"?7\"?)#|\tfirst Sunday of month at \2:\1\t \t \t \t \t\3#g       ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?0\"? *-eq .*)#|\tfirst Sunday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?1\"? *-eq .*)#|\tfirst Monday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?2\"? *-eq .*)#|\tfirst Tuesday of month at \2:\1\t \t \t \t \t\3#g   ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?3\"? *-eq .*)#|\tfirst Wednesday of month at \2:\1\t \t \t \t \t\3#g ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?4\"? *-eq .*)#|\tfirst Thursday of month at \2:\1\t \t \t \t \t\3#g  ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?5\"? *-eq .*)#|\tfirst Friday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?6\"? *-eq .*)#|\tfirst Saturday of month at \2:\1\t \t \t \t \t\3#g  ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t1-7\t\*\t\*\t(.*\"?7\"? *-eq .*)#|\tfirst Sunday of month at \2:\1\t \t \t \t \t\3#g    ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*1,2,3,4,5\t#|\teach weekday at \2:\1\t \t \t \t \t#g                       ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*1\t#|\teach Monday at \2:\1\t \t \t \t \t#g                                ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*2\t#|\teach Tuesday at \2:\1\t \t \t \t \t#g                               ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*3\t#|\teach Wednesday at \2:\1\t \t \t \t \t#g                             ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*4\t#|\teach Thursday at \2:\1\t \t \t \t \t#g                              ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*5\t#|\teach Friday at \2:\1\t \t \t \t \t#g                                ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*6\t#|\teach Saturday at \2:\1\t \t \t \t \t#g                              ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t\*\t\*\t0*7\t#|\teach Sunday at \2:\1\t \t \t \t \t#g                                ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t\*\t\*%(.*)%\t0#|\tSun @\1\t \t \t \t #g                                                           ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t1\t\*\t\*#|\t@start of each month\t \t \t \t #g                                                    ;  \
                                s#\|\t98\t98\t1\t\*\t\*#|\tmonthly (anacron)\t \t \t \t #g                                                     ;  \
                                s#\|\t([0-9]*)\t([0-9]*)\t([0-9]*)\t\*\t\*#|\tday \3 of month at \2:\1\t \t \t \t #g                           ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t35\t\*%(.*)%\t\*#|\tfirst @\1\t \t \t \t #g                                                        ;  \
                                                                                                                                                  \
                                s#\|\t0\t0\t1\t1\t\*#|\t@start of each year\t \t \t \t # "                                                        \
                        )

#echo "sortedLinesTranslated (unescaped) ="
#echo "${sortedLinesTranslated}" | sed "s#${tab}#<tab>#g"
#echo "-------------------"

#echo "sortedLinesTranslated   (escaped) ="
#echo -e "${sortedLinesTranslated}"  | sed "s#${tab}#<tab>#g"
#echo "-------------------"

if ${showProgress} ; then echo  "C"; fi

if ! ${quiet}
then
    cat <<EOS

========================================================================================================================
Common timing intervals below are converted to more readable form.

However some more obscure possible combinations
 ( such as "run at 3AM on the first Friday of each month" )
 are not handled, and will show using the original
     min  hour  day-of-month  month  day-of-week
 format

 Anacron timings are printed in a rather cryptic code.

  executable      | anacron_3-22[~45]   | daily                        root  /etc/cron.daily/logrotate

    ( meaning tasks can only start between 03:00 and 22:00 hours,
       and will be randomly delayed up to 45 minutes ).

    If we are only using daily/weekly/monthly anacron lists.
     you would think tasks would start somewhere near the beginning of the permitted window.
     ( which is what we observe ).
    It seems the 22:00 info is only useful for situations when mains power is restored,
     and all the cron tasks we didn't want to run on battery become 'eligible'.
    It may also have an influence on the per-anacron-task delay we currently ignore.

 should be read as:

  executable      | anacron             | daily < 45 mins after 03:00  root  /etc/cron.daily/logrotate

------------------------------------------- Cron tasks found on this machine -------------------------------------------

EOS
fi

echo "In the table below, entries labelled 'IS/ARE DISABLED' or 'MISSING' mean that"
echo "  even if the cron job is executable ( which in such cases we do not bother testing )"
echo " we observe that the scripts invoked will exit without taking any action."
echo

################################################ emit the big table ####################################################

#
# Narrow the empty area in front of the user names when possible
# We now drop the 3 or 4 empty tabbed columns completely if they are present on all lines.
#
if echo "${sortedLinesTranslated}" | grep -Eq "\|${tab}[0-9]|\|${tab}\*/"    # All numeric formats start with some digit or */ I think
then
    # Some entry remains in numeric format
    sortedLinesHdr="$(echo    " notes${tab}| location${tab}|${tab}min${tab}hr${tab}dom${tab}mo${tab}dow${tab}user${tab}command" )";
else
    # All entries are in summarised format
    sortedLinesHdr="$(echo    " notes${tab}| location${tab}|${tab}description${tab}user${tab}command" )";

    sortedLinesTranslated="$(echo "${sortedLinesTranslated}" | sed 's# \t \t \t \t##g')"
fi

# We have to include the header line when aligning columns.
sortedLinesXlHdr="$(echo    "${sortedLinesHdr}";        \
                    echo -e "${sortedLinesTranslated}"  \
                   )"

# Remove disabled test scripts from the list.
#
sortedLinesXlHdr="$(echo "${sortedLinesXlHdr}" | grep -Ev "NOT EXECUTABLE.*test-.*-cron|BAD RUN-PARTS FILENAME.*test-cron.*\.sh" )"

#echo "sortedLinesXlHdr (unescaped) ="
#echo "${sortedLinesXlHdr}"  | sed "s#${tab}#<tab>#g"
#echo "-------------------"

#echo "sortedLinesXlHdr   (escaped) ="
#echo -e "${sortedLinesXlHdr}"  | sed "s#${tab}#<tab>#g"
#echo "-------------------"

if ${showProgress} ; then echo  "->"; fi

inactiveGrepMatch="BAD RUN-PARTS FILENAME|SYSSTAT IS DISABLED|NOT EXECUTABLE|PKG STATES MISSING|NTP STATS ARE DISABLED|BSD UTILS DISABLED"

captured="$( { echo -e "${sortedLinesXlHdr}" | grep -Ev "${inactiveGrepMatch}";  \
               echo "!!separ!ator!!";                                            \
               echo -e "${sortedLinesXlHdr}" | grep -E  "${inactiveGrepMatch}";  \
             }                                                                |  \
             sed 's#|\t#| #g'                                                 |  \
             column -s"${tab}" -t                                             |  \
             cut -c1-${screenColumns}                                            \
           )"

echo "$captured" | head -n1
echo "${screenWidthSeparator}"
echo "$captured" | tail -n +2 | sed "s#!!separ!ator!!#${screenWidthSeparator}#g"
echo

echo "Any task which is currently NOT EXECUTABLE and whose name matches '*test-*-cron*' ( so it's a cron test script )"
echo " and any which match 'test-cron*.sh'."
echo " have been removed from that list for clarity."

########################################## show things scheduled by 'at' ###############################################

# If we have a LONG list of cron-tasks these dividers can make the output too long - could usefully make them conditional.
echo
echo "--------------------------------------------------------------------------------------------------------------"
echo

if ! which atq > /dev/nul 2>&1
then
    echo "The 'at' command is not provided on this unit, so no such tasks can ever be scheduled."
else
    if [ -n "$(atq)" ]
    then
        echo "There are one or more jobs waiting to be executed by the 'at' command."
        echo "While they don't form part of what this script was created to examine,"
        echo " here is a list for your information:"
        echo ""
        atq
    else
        echo "The 'at' command is provided on this unit, but there are no tasks for it to show."
    fi
fi

if [ -d /run/systemd/system/ ] 
then :
    # If we have a LONG list of cron-tasks these dividers can make the output too long - could usefully make them conditional.
    echo
    echo "--------------------------------------------------------------------------------------------------------------"
    echo "Here is a terse summary of systemd timers:"
    echo

    echo "    ( On a box in the field we would expect to see we have disabled the man-db and apt-daily timers. )"
    echo
    {
        for timerName in $( {
                                # It is expected that there can be no .timer files in one or other of these locations,
                                #  so we suppress the associated warning which is issued to stderr.
                                #
                                # I have verified that an empty 'in' section does nothing without issuing any error.
                                #
                                for timerAPAFN in $( ls  /usr/lib/systemd/user/*.timer  /lib/systemd/system/*.timer 2> /dev/null )
                                do :
                                    echo $timerAPAFN | rev | cut -d'.' -f 2 | cut -d'/' -f1 | rev 
                                done
                            } | sort | uniq
                         )
        do
            # If a timer is not active we still emit its name frollowed by a colon, but nothing after.
            #
            echo "$timerName : $(systemctl status $timerName.timer | grep "Active:")"
        done
    } |  column -t | grep -o ".*)" | sort -k5,5 
fi

echo ""
