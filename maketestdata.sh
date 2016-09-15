#!/bin/sh


HOME=/Users/gary
BASE=test

BASE=test
DIRDEPTH=5
NUMFILES=1024
FILESIZE=$((1024))

###############################################################################

function random_data {
    num_bytes=$(($1 / 2))
    cat /dev/urandom \
        | od -N "$num_bytes" -t x1 \
        | sed 's/^[0-9a-f]*//g;' \
        | tr -d ' \n'
}

###############################################################################

function md5_file {
    md5 -r $1 | awk '{print $1}'
}

###############################################################################

function random_path {
    depth=$(($RANDOM % $1 + 1))
    path="" 
    for i in `eval echo {1..$depth}`; do
        digit=$(($RANDOM % 10))
        if [ -z "$path" ]; then
            path="$digit"
        else
            path="$path/$digit"
        fi
    done
    echo $path
}

###############################################################################

function make_data {    
    tmp="$BASE/tmp"
    for i in `eval echo {1..$NUMFILES}`; do
        path=`random_path $DIRDEPTH`
        while [ -f "$path" ]; do
            path=`random_path $DIRDEPTH`
        done
        random_data $FILESIZE > "$tmp"
        name=`md5_file $tmp`
        mkdir -p "$BASE/$path"
        mv "$tmp" "$BASE/$path/$name"
    done
}

###############################################################################

function main {
    cd $HOME
    rm -rf "$BASE"
    mkdir  "$BASE"
    ssh diskstation rm -rf "$BASE"
    ssh maxi rm -rf "$BASE"

    make_data
    rsync -a --delete "$BASE" diskstation:.
    sh sync/sync.sh init
    rsync -aH "$BASE" maxi:.
    ssh diskstation ln -s "../versions/0" "$BASE/.sync/clients/Maxi"        
}

###############################################################################

#main

cd $HOME
rm -rf "$BASE"
mkdir  "$BASE"
make_data
 
