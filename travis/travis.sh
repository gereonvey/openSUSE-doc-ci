#!/bin/bash -e
#
# From the GitHub repository:
# https://github.com/openSUSE/doc-ci
#
# License: MIT
#
# Written by Thomas Schraitle

RED='\e[31m'
GREEN='\e[32m'
BLUE='\e[34m'
BOLD='\e[1m'
RESET='\e[0m' # No Color

DCVALIDATE=".travis-check-docs"

# Configuration file for navigation page
BRANCHCONFIG='https://raw.githubusercontent.com/SUSEdoc/susedoc.github.io/master/index-config.xml'


DAPS="daps"
# Setting --styleroot makes sure that DAPS does not error out when the
# stylesheets requested by the DC file are not available in the container.
DAPS_SR="$DAPS --styleroot /usr/share/xml/docbook/stylesheet/suse2013-ns/"

# How many commits do we allow to accumulate in publishing repos before we
# reset the repo?
MAXCOMMITS=35


log() {
  # $1 - optional: string: "+" for green color, "-" for red color
  # $2 - message
  colorcode="$BLUE"
  [[ "$1" == '+' ]] && colorcode="$GREEN" && shift
  [[ "$1" == '-' ]] && colorcode="$RED" && shift
  echo -e "$colorcode${1}$RESET"
}

fail() {
  # $1 - message
  echo -e "$RED$BOLD${1}$RESET"
  exit 1
}

succeed() {
  # $1 - message
  echo -e "$GREEN$BOLD${1}$RESET"
  exit 0
}


mkdir -p /root/.config/daps/
echo DOCBOOK5_RNG_URI="https://github.com/openSUSE/geekodoc/raw/master/geekodoc/rng/geekodoc5-flat.rnc" > /root/.config/daps/dapsrc

source env.list
PRODUCT=$(echo $TRAVIS_BRANCH | sed -e 's/maintenance\///g')
REPO=$(echo $TRAVIS_REPO_SLUG | sed -e 's/.*\///g')
echo "TRAVIS_REPO_SLUG=\"$TRAVIS_REPO_SLUG\""
echo "REPO=\"$REPO\""
echo "TRAVIS_BRANCH=\"$TRAVIS_BRANCH\""
echo "PRODUCT=\"$PRODUCT\""
echo "TRAVIS_PULL_REQUEST=\"$TRAVIS_PULL_REQUEST\""

if [ $LIST_PACKAGES -eq "1" ] ; then
  rpm -qa | sort
fi


# Determine whether we want to build HTML or we only want to validate
BUILDDOCS=0
DCBUILDLIST=

CONFIGXML=$(curl -s "$BRANCHCONFIG")

# If $CONFIGXML is a valid XML document and produces no errors...
if [[ ! $(echo -e "$CONFIGXML" | xmllint --noout --noent - 2>&1) ]]; then
    RELEVANTCATS=$(echo -e "$CONFIGXML" | xml sel -t -v '//cats/cat[@repo="'"$REPO"'"]/@id')

    RELEVANTBRANCHES=
    for CAT in $RELEVANTCATS; do
        RELEVANTBRANCHES+=$(echo -e "$CONFIGXML" | xml sel -t -v '//doc[@cat="'"$CAT"'"]/@branches')'\n'
    done

    RELEVANTBRANCHES=$(echo -e "$RELEVANTBRANCHES" | tr ' ' '\n' | sort -u)

    if [[ $(echo -e "$RELEVANTBRANCHES" | grep "^$TRAVIS_BRANCH\$") ]] || \
       [[ $(echo -e "$RELEVANTBRANCHES" | grep "^$PRODUCT\$") ]]; then
        log "Enabling builds.\n"
        BUILDDOCS=1
        for CAT in $RELEVANTCATS; do
            for BRANCHNAME in "$TRAVIS_BRANCH" "$PRODUCT"; do
                DCBUILDLIST+=$(echo -e "$CONFIGXML" | xml sel -t -v '//doc[@cat="'"$CAT"'"][@branches[contains(concat(" ",.," "), " '"$BRANCHNAME"' ")]]/@doc')'\n'
            done
        done
        DCBUILDLIST=$(echo -e "$DCBUILDLIST" | tr ' ' '\n' | sed -r 's/^(.)/DC-\1/' | sort -u)
        [[ -z "$DCBUILDLIST" ]] && log "No DC files enabled for build. $BRANCHCONFIG is probably invalid.\n"
    fi
else
    log "Cannot determine whether to build, configuration file $BRANCHCONFIG is unavailable or invalid. Will not build.\n"
fi

DCLIST=$(ls DC-*-all)
if [[ -f "$DCVALIDATE" ]]; then
    DCLIST=$(cat "$DCVALIDATE")
elif [ -z "$DCLIST" ] ; then
    DCLIST=$(ls DC-*)
fi

# Do this first, so this fails as quickly as possible.
unavailable=
for DCFILE in $DCLIST; do
    [[ ! -f $DCFILE ]] && unavailable+="$DCFILE "
done
if [[ ! -z $unavailable ]]; then
    fail "DC file(s) is/are configured in $DCVALIDATE but not present in repository:\n$unavailable"
fi


echo -e '\n'
for DCFILE in $DCLIST; do
    log "Validating $DCFILE (with $(rpm -qv geekodoc))...\n"
    $DAPS_SR -vv -d $DCFILE validate || exit 1
    log "\nChecking for missing images in $DCFILE ...\n"
    MISSING_IMAGES=$($DAPS_SR -d $DCFILE list-images-missing)
    if [ -n "$MISSING_IMAGES" ]; then
        fail "Missing images:\n$MISSING_IMAGES"
    else
        log + "All images available."
    fi
    echo -e '\n\n\n'
    wait
done

TEST_NUMBER='^[0-9]+$'
if [[ $TRAVIS_PULL_REQUEST =~ $TEST_NUMBER ]] ; then
    succeed "This is a Pull Request.\nExiting cleanly.\n"
fi

if [[ $BUILDDOCS -eq 0 ]]; then
    succeed "The branch $TRAVIS_BRANCH is not configured for builds.\n(If that is unexpected, check whether the $PRODUCT branch of this repo is configured correctly in the configuration file at $BRANCHCONFIG.)\nExiting cleanly.\n"
fi

buildunavailable=
for DCFILE in $DCBUILDLIST; do
    [[ ! -f $DCFILE ]] && buildunavailable+="$DCFILE "
done
if [[ ! -z $buildunavailable ]]; then
    fail "DC file(s) is/are configured in $BRANCHCONFIG but not present in repository:\n$buildunavailable"
fi

if [[ -z "$DCBUILDLIST" ]]; then
    fail "The branch $TRAVIS_BRANCH is enabled for building but there are no valid DC files configured for it. This should never happen. If it does, $BRANCHCONFIG is invalid or the travis.sh script from doc-ci is buggy.\n"
fi


# Decrypt the SSH private key
openssl aes-256-cbc -pass "pass:$ENCRYPTED_PRIVKEY_SECRET" -in ./ssh_key.enc -out ./ssh_key -d -a
# SSH refuses to use the key if its readable to the world
chmod 0600 ssh_key
# Start the SSH authentication agent
eval $(ssh-agent -s)
# Display the key fingerprint from the file
ssh-keygen -lf ssh_key
# Import the private key
ssh-add ssh_key
# Display fingerprints of available SSH keys
ssh-add -l

# Set the git username and email used for the commits
git config --global user.name "Travis CI"
git config --global user.email "$COMMIT_AUTHOR_EMAIL"

# Build HTML and single HTML as drafts
for DCFILE in $DCBUILDLIST; do
    styleroot=$(grep -P '^\s*STYLEROOT\s*=\s*' $DCFILE | sed -r -e 's/^[^=]+=\s*["'\'']//' -e 's/["'\'']\s*//')
    dapsbuild=$DAPS
    if [[ ! -d "$styleroot" ]]; then
      dapsbuild=$DAPS_SR
      log - "$DCFILE requests style root $styleroot which is not installed. Replacing with default style root."
    fi
    log "\nBuilding HTML for $DCFILE ...\n"
    $dapsbuild -d $DCFILE html --draft
    log "\nBuilding single HTML for $DCFILE ...\n"
    $dapsbuild -d $DCFILE html --single --draft
    wait
done

# Now clone the GitHub pages repository, checkout the gh-pages branch and clean files
mkdir ~/.ssh
ssh-keyscan github.com >> ~/.ssh/known_hosts
log "Cloning GitHub Pages repository\n"
git clone ssh://git@github.com/SUSEdoc/$REPO.git /tmp/$REPO

GIT="git -C /tmp/$REPO/"
BRANCH=gh-pages

$GIT checkout $BRANCH

# Every 35 commits ($MAXCOMMITS), we reset the repo, so it does not become too
# large. (When the repo becomes too large, that raises the probability of
# Travis failing.)
if [[ $(PAGER=cat $GIT log --oneline --format='%h' | wc -l) -gt $MAXCOMMITS ]]; then
  log "Resetting repository, so it does not become too large\n"
  # nicked from: https://stackoverflow.com/questions/13716658
  $GIT checkout --orphan new-branch
  $GIT add -A . >/dev/null
  $GIT commit -am "Repo state reset by travis.sh"
  $GIT branch -D $BRANCH
  $GIT branch -m $BRANCH
  $GIT push -f origin $BRANCH
fi

rm -r /tmp/$REPO/$PRODUCT


# Copy the HTML and single HTML files for each DC file
for DCFILE in $DCBUILDLIST; do
    MVFOLDER=$(echo $DCFILE | sed -e 's/DC-//g')
    htmldir=/tmp/$REPO/$PRODUCT/$MVFOLDER/html/
    shtmldir=/tmp/$REPO/$PRODUCT/$MVFOLDER/single-html/
    log "Moving $DCFILE...\n"
    mkdir -p $htmldir $shtmldir
    log "  /usr/src/app/build/$MVFOLDER/html -> $htmldir"
    mv /usr/src/app/build/$MVFOLDER/html/*/* $htmldir
    log "  /usr/src/app/build/$MVFOLDER/single-html -> $shtmldir"
    mv /usr/src/app/build/$MVFOLDER/single-html/*/* $shtmldir
    log "Adding Beta warning messages to HTML files"
    # We need to avoid touching files twice (the regex is not quite safe
    # enough for that), hence it is important to exclude symlinks.
    warnfiles=$(find $htmldir -type f -name '*.html')' '$(find $shtmldir -type f -name '*.html')
    for warnfile in $warnfiles; do
      sed -r -i 's/(<\/head><body[^>]*)>/\1 onload="if (document.cookie.length > 0) {if (document.cookie.indexOf('"'"'betawarn=closed'"'"') != -1){$('"'"'#betawarn'"'"').toggle()}};"><div id="betawarn" style="position:fixed;bottom:0;z-index:9025;background-color:#E11;padding:1em;color:#FFF;margin-left:10%;margin-right:10%;display:block;"><p style="color: #FFF;">This documentation is not official. It is built and uploaded automatically. It may document beta software and at times be incomplete or even incorrect. <strong>Use the documents provided here at your own risk.<\/strong><\/p> <a href="#" onclick="$('"'"'#betawarn'"'"').toggle();var d=new Date();d.setTime(d.getTime()+(0.5*24*60*60*1000));document.cookie='"'"'betawarn=closed; expires='"'"'+d.toUTCString()+'"'"'; path=\/'"'"';" style="color:#FFF;text-decoration:underline;float:left;margin-top:.5em;padding:1em;display:block;background-color:rgba(255,255,255,.3);">Close<\/a><\/div>/' $warnfile
    done
    echo -e '\n\n\n'
    wait
done

# Add all changed files to the staging area, commit and push
log "Deploying build results from original commit $TRAVIS_COMMIT (from $REPO) to GitHub Pages."
$GIT add -A .
log "Commit"
$GIT commit -m "Deploy to GitHub Pages: ${TRAVIS_COMMIT}"
log "Push"
$GIT push origin $BRANCH

succeed "We're done."
