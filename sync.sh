#!/bin/sh

HOME=/Users/gary
BASE=test
REMOTE=diskstation
LOCAL=$(hostname -s)


###############################################################################

function help {
    echo Neeed to write help sections
}

###############################################################################

function rsh {
    ssh -qn -oConnectTimeout=1 -oBatchMode=yes "$REMOTE" $@
}

###############################################################################

function error {
    prefix="error:"
    for msg in "$@"; do
        echo "$prefix" "$msg" 1>&2 
        prefix="      "
    done
    exit 1
}

###############################################################################

function log {
    if [ ! -d "$BASE/.sync" ]; then
        return
    fi
    local prefix=$(date "+%Y/%m/%d %H:%M:%S [$$]")
    for msg in "$@"; do
        echo "$prefix # $msg" >> "$BASE/.sync/log"
    done
}

###############################################################################

function sanity_checks {
    log "Performing sanity checks."
    
    # Check that the base directory exists
    if [ ! -d "$HOME/$BASE" ]; then
        error "sync directory $HOME/$BASE does not exist."
    fi

    # Check all files within $BASE are owned by the user running the script.
    local whoami=$(whoami)
    local notowned=$(find $BASE -not -user $whoami -print | wc -l | tr -d ' ')
    if [ "$notowned" != "0" ]; then
        error "$notowned file(s) within $BASE not owned by $whoami" \
              "Consider running: 'sudo chown -R $whoami $BASE'."
    fi
    
    # Check that all files within $BASE are unlocked.
    local locked=$(find $BASE -flags uchg -print | wc -l | tr -d ' ')
    if [ "$locked" != "0" ]; then
        local cmd="'find $BASE -flags uchg -exec chflags nouchg {} \;'"
        error "$locked file(s) within $BASE locked" \
              "Consider running: $cmd."
    fi

    # Check that the remote end point is up and reachable
    ping -c 1 "$REMOTE" > /dev/null 2>&1
    if [ $? != 0 ]; then
        error "remote host $REMOTE is unreachable"
    fi
    
    # Check that the user can ssh into the server
    rsh true > /dev/null 2>&1
    if [ $? != 0 ]; then
        error "unable to ssh to $REMOTE." \
              "You may need to setup public ssh keys on $REMOTE."
    fi

    # Check that the remote base directory exists.
    rsh test -d "$BASE" > /dev/null 2>&1
    if [ $? != 0 ]; then
        error "$BASE directory does not exist on $REMOTE." 
    fi
    
}

###############################################################################

function initialize_local_sync {
    rm -rf "$BASE/.sync"
    mkdir -p "$BASE/.sync/versions"
    log "initializing local sync..."
    
    rsync -a --delete \
          --exclude=.sync \
          --log-file="$BASE/.sync/log" \
          --link-dest=../../.. \
          "$BASE/" "$BASE/.sync/versions/0"

    log "local sync initialized"
}

###############################################################################

function initialize_remote_sync {
    log "initializing remote sync"
    rsh rm -rf "$BASE/.sync"
    rsh mkdir -p "$BASE/.sync/versions"
    rsh mkdir -p "$BASE/.sync/clients"
    
    rsh rsync -a --delete \
        --exclude=.sync \
        --link-dest=../../.. \
        "$BASE/" "$BASE/.sync/versions/0" \
        >> "$BASE/.sync/log"
    
    rsh ln -s "../versions/0" "$BASE/.sync/clients/$LOCAL" 

    log "remote sync initialized"
}

###############################################################################

function acquire_lock {
    log "acquiring lock"

    local lock="$BASE/.sync/lock"
    rsh "test \! -f $lock && touch $lock"
    if [ $? != 0 ]; then
        error "Unable to acquire server lock.  Please try again later."
    fi
}

###############################################################################

function release_lock {
    log "releasing lock"
    
    local lock="$BASE/.sync/lock"
    rsh "rm $lock > /dev/null 2>&1"
    if [ $? != 0 ]; then
        error "Unable to release server lock.  This will cause problems later."
    fi
}

###############################################################################

function find_local_updates {
    log "finding local updates"

    local lvnum=$1
    local rebase="$BASE/.sync/versions/$lvnum"
    
    ( cd $BASE; find . -type f -not -path './.sync/*' -print ) \
        > "$BASE/.sync/new"
    ( cd $rebase; find . -type f -print ) > "$BASE/.sync/old"

    cat "$BASE/.sync/old" "$BASE/.sync/new" | sort -u > "$BASE/.sync/all"
    
    rm -f "$BASE/.sync/additions"
    rm -f "$BASE/.sync/deletions"
    touch "$BASE/.sync/additions"
    touch "$BASE/.sync/deletions"
    
    
    cat "$BASE/.sync/all" | (
        while read fname; do
            if [ "$BASE/$fname" -ef "$rebase/$fname" ]; then
                continue
            elif [ -f "$BASE/$fname" ]; then
                echo "$fname" >> "$BASE/.sync/additions"
            else
                echo "$fname" >> "$BASE/.sync/deletions"
            fi            
        done
    )
    
    cat "$BASE/.sync/additions" "$BASE/.sync/deletions" \
        > "$BASE/.sync/updates"
}

###############################################################################

function pull_remote_version {
    local lvnum=$1
    local rvnum=$2
    
    if [ "$rvnum" -eq "$lvnum" ]; then
        log "skipping pull because local and remote versions match"
        return
    fi
    
    log "pulling remote version $rvnum via local version $lvnum"
    rsync -aHO \
          --log-file="$BASE/.sync/log" \
          --delete-after \
          "$REMOTE:$BASE/.sync/versions/$lvnum" \
          "$REMOTE:$BASE/.sync/versions/$rvnum" \
          "$BASE/.sync/versions"
}

###############################################################################

function apply_remote_updates {
    local lvnum=$1
    local rvnum=$2
    local nvnum=$3

    log "applying updates from version $rvnum to $nvnum"
    if [  "$rvnum" -ne "$lvnum" ]; then
        mv "$BASE/.sync/versions/$lvnum" "$BASE/.sync/versions/$nvnum"
    else
        rsync -a --delete \
          --log-file="$BASE/.sync/log" \
          --link-dest=../../.. \
          "$BASE/.sync/versions/$lvnum/" \
          "$BASE/.sync/versions/$nvnum"
    fi
              

    rsync -aHO \
          --log-file="$BASE/.sync/log" \
          --delete-after \
          --link-dest=../../.. \
          "$BASE/.sync/versions/$rvnum/" \
          "$BASE/.sync/versions/$nvnum"
}

###############################################################################

function apply_local_updates {
    local nvnum=$1
    
    log "applying local updates to version $nvnum"
    
    rsync -aHO \
          --log-file="$BASE/.sync/log" \
          --exclude=.sync \
          --include-from="$BASE/.sync/updates" \
          --delete-after \
          --link-dest=../../.. \
          "$BASE/" \
          "$BASE/.sync/versions/$nvnum"

    log "applying local updates to version $nvnum"

    rsync -a --delete \
          --exclude=.sync \
          --link-dest=../../.. \
          "$BASE/.sync/versions/$nvnum/" "$BASE" \
          >> "$BASE/.sync/log"
}

###############################################################################

function push_new_remote {
    local rvnum=$1
    local nvnum=$2

    log "pushing new remote version $nvnum via version $rvnum"
    
    rsync -aHO \
          --log-file="$BASE/.sync/log" \
          --delete-after \
          "$BASE/.sync/versions/$rvnum" \
          "$BASE/.sync/versions/$nvnum" \
          "$REMOTE:$BASE/.sync/versions"

    rsh rm -f "$BASE/.sync/clients/$LOCAL"

    rsh ln -s "../versions/$nvnum" "$BASE/.sync/clients/$LOCAL"

    rsh rsync -a --delete \
        --exclude=.sync \
        --link-dest=../../.. \
        "$BASE/.sync/versions/$nvnum/" "$BASE" \
        >> "$BASE/.sync/log"
    
    # Need to have remote code to garbage collect versions    
}

###############################################################################

function sync {
    sanity_checks
    acquire_lock
    local lvnum=$(ls "$BASE/.sync/versions" | sort -rn | head -1)
    local rvnum=$(rsh ls "$BASE/.sync/versions" | sort -rn | head -1)
    find_local_updates $lvnum
    pull_remote_version $lvnum $rvnum    
    local nvnum=$(($rvnum + 1))
    apply_remote_updates $lvnum $rvnum  $nvnum
    apply_local_updates $nvnum
    push_new_remote $rvnum $nvnum
    release_lock
}

###############################################################################

function status {
    # Inspect the local and remote machines to see if they are in a good
    # state.
    
    rsh test -d "$BASE/.sync"
    local remote_stat=$?

    test -d "$BASE/.sync"
    local local_stat=$?
    
    rsync -aiunO --delete --exclude=.sync/ "$BASE/" "$REMOTE:$BASE" \
          > /tmp/sync.$$
    local push_add=$(grep '^[<>]' /tmp/sync.$$ | wc -l | tr -d ' ')
    local push_del=$(grep '^*deleting' /tmp/sync.$$ | wc -l | tr -d ' ')
    
    rsync -aiunO --delete --exclude=.sync/ "$REMOTE:$BASE/" "$BASE"  \
          > /tmp/sync.$$
    local pull_add=$(grep '^[<>]' /tmp/sync.$$ | wc -l | tr -d ' ')
    local pull_del=$(grep '^*deleting' /tmp/sync.$$ | wc -l | tr -d ' ')
    
    if [ $local_stat -eq 0 ]; then
        if [ $remote_stat -eq 0 ]; then
            echo Local and remote syncs appear ready.
        else
            echo Local sync appears ready but remote is not.
        fi        
    else
        if [ $remote_stat -eq 0 ]; then
            echo Remote sync appears ready but local is not.
        else
            echo Neither local nor remote sync are ready.
        fi
    fi

    echo Push would update $push_add files and delete $push_del files.
    echo Pull would update $pull_add files and delete $pull_del files.
}

###############################################################################

function main {
    if [ ! -d "$HOME" ]; then
        error "Home directory $HOME does not exist."
    fi
    cd "$HOME"
    
    while true; do        
        case $1 in
            -h|-\?|--help)
                help
                exit 0
                ;;
            -d|--debug)
                DEBUG=1
                ;;
            status)
                sanity_checks
                status
                ;;
            init)
                sanity_checks
                initialize_local_sync
                initialize_remote_sync
                ;;
            push)
                ;;
            pull)
                ;;
            sync)
                sync
                ;;
            clean)
                ;;
            *)
                break
                ;;
        esac
        shift
    done
}

###############################################################################

main $*

