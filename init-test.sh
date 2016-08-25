#!/bin/sh

HOME=/Users/gary
BASE=test
REMOTE=diskstation

###############################################################################

function rsh {
    ssh -qn -oConnectTimeout=1 -oBatchMode=yes "$REMOTE" $@
}

###############################################################################

cd $HOME
rm -rf test
rsh rm -rf test
cd sync
sh test-data.sh
mv test ..
cd ..
rsync -av test $REMOTE:.



