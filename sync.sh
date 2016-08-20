#!/bin/sh

HOME=/Users/gary
BASE=Home
HOST=diskstation
LOCAL=$(hostname -s)

DEBUG=0

################################################################################

function help {
    echo help
}

################################################################################

function rsh {
    ssh -qn -oConnectTimeout=1 -oBatchMode=yes "$HOST" $@
}

################################################################################

function error {
    prefix="error:"
    for msg in "$@"; do
        echo "$prefix" "$msg" 1>&2 
        prefix="      "
    done
    exit 1
}

################################################################################

function log {
    prefix=`date "+%Y/%m/%d %H:%M:%S [$$]"`
    for msg in "$@"; do
        echo "$prefix # $msg" >> "$BASE/.sync/log"
    done
}

################################################################################

function sanity_checks {
    # Check that the base directory exists
    if [ ! -d "$HOME/$BASE" ]; then
        error "sync directory $HOME/$BASE does not exist."
    fi

    # Check all files within $BASE are owned by the user running the script.
    WHOAMI=`whoami`
    NOTOWNED=`find $BASE -not -user $WHOAMI -print | wc -l | tr -d ' '`
    if [ "$NOTOWNED" != "0" ]; then
        error "$NOTOWNED file(s) within $BASE not owned by $WHOAMI" \
              "Consider running: 'sudo chown -R $WHOAMI $BASE'."
    fi
    
    # Check that all files within $BASE are unlocked.
    LOCKED=`find $BASE -flags uchg -print | wc -l | tr -d ' '`
    if [ "$LOCKED" != "0" ]; then
        echo HELLO
        CMD="'find $BASE -flags uchg -exec chflags nouchg {} \;'"
        error "$LOCKED file(s) within $BASE locked" \
              "Consider running: $CMD."
    fi

    # Check that the remote end point is up and reachable
    ping -c 1 "$HOST" > /dev/null 2>&1
    if [ $? != 0 ]; then
        error "remote host $HOST is unreachable"
    fi
    
    # Check that the user can ssh into the server
    rsh true > /dev/null 2>&1
    if [ $? != 0 ]; then
        error "unable to ssh to $HOST." \
              "You may need to setup public ssh keys on $HOST."
    fi

    # Check that the remote base directory exists.
    rsh test -d "$BASE" > /dev/null 2>&1
    if [ $? != 0 ]; then
        error "$BASE directory does not exist on $HOST." 
    fi
    
}

################################################################################

function acquire_lock {
    log "acquiring lock"

    lock="$BASE/.sync/lock"
    rsh "test \! -f $lock && touch $lock"
    if [ $? != 0 ]; then
        error "Unable to acquire server lock.  Please try again later."
    fi
}

################################################################################

function release_lock {
    log "releasing lock"

    lock="$BASE/.sync/lock"
    rsh "rm $lock > /dev/null 2>&1"
    if [ $? != 0 ]; then
        error "Unable to release server lock.  This will cause problems later."
    fi
}

################################################################################

function rebuild_local_shadow {
    log "rebuilding local shadow"

    rsync "$DBG" -a --delete \
          --exclude=/.shadow \
          --exclude=/.sync \
          --log-file="$BASE/.sync/log" \
          --link-dest=.. \
          "$BASE/" "$BASE/.shadow"
}

################################################################################

function initialize_local_sync {
    rm -rf "$BASE/.sync"
    mkdir -p "$BASE/.sync/versions"

    log "initializing local shadow"
    
    rsync "$DBG" -a --delete \
          --exclude=.sync \
          --log-file="$BASE/.sync/log" \
          --link-dest=../../.. \
          "$BASE/" "$BASE/.sync/versions/0"
}

################################################################################

function rebuild_remote_shadow {
    log "rebuilding remote shadow"

    rsh "$HOST" "rsync $DBG -a --delete \
      --exclude=/.sync \
      --link-dest=.. \
      $BASE/ $BASE/.shadow" \
        >> "$BASE/.sync/log"
}

################################################################################

function initialize_remote_sync {
    log "initializing remote shadow"

    rsh rm -rf "$BASE/.sync"
    rsh mkdir -p "$BASE/.sync/versions"
    rsh mkdir -p "$BASE/.sync/clients"
    
    rsh rsync "$DBG" -a --delete \
        --exclude=.sync \
        --link-dest=../../.. \
        "$BASE/" "$BASE/.sync/versions/0" \
        >> "$BASE/.sync/log"

    rsh ln -s "$BASE/.sync/versions/0" "$BASE/.sync/clients/$LOCAL" 
}

################################################################################

function find_exclusions {
    log "finding exclusions"

    find "$BASE" -type f -links 1 \
         -not -path "$BASE/.shadow/*"  \
         -not -path "$BASE/.sync/*" \
         -print > "$BASE/.sync/additions"

    find "$BASE"/.shadow -type f -links 1 \
         -print > "$BASE/.sync/deletions"


    echo '.DS_Store' > "$BASE/.sync/exclusions"

    echo '/Home/.sync' >> "$BASE/.sync/exclusions"

    cat "$BASE/.sync/additions" \
        | sed 's/\(.*\)/\/\1/g' \
              >> "$BASE/.sync/exclusions"

    cat "$BASE/.sync/additions" \
        | sed 's/^\('"$BASE"'\/\)/\/\1.shadow\//g' \
              >> "$BASE/.sync/exclusions"

    cat "$BASE/.sync/deletions" \
        | sed 's/\(.*\)/\/\1/g' \
              >> "$BASE/.sync/exclusions"

    cat "$BASE/.sync/deletions" \
        | sed 's/^\('"$BASE"'\/\).shadow\//\/\1/g' \
              >> "$BASE/.sync/exclusions"
}

################################################################################

function pull_from_remote {
    log "pull from remote to local"

    rsync "$DBG" -abHu \
          --backup-dir="$BASE/.sync/backup" \
          --exclude-from="$BASE/.sync/exclusions" \
          --log-file="$BASE/.sync/log" \
          --delete-after \
          "$HOST":"$BASE" .
}

################################################################################

function delete_locally {
    log "deleting local files"

    cat "$BASE/.sync/deletions" | (
        while read line; do
            log "deleting $line"
            if [ $DEBUG != 0 ]; then
                /bin/rm -f "$line"
            fi
        done
    )
}

################################################################################

function push_from_local {
    log "push from local to remote"

    rsync "$DBG" -qaHu \
          --exclude ".DS_Store" \
          --exclude "$BASE/.sync/" \
          --log-file="$BASE/.sync/log" \
          --delete-after \
          "$BASE" "$HOST":.
}

################################################################################

function sync_machines {
    # Need to optionally rebuild shadow directory if it doesm't exist

    if [ ! -d "$BASE/.shadow" ]; then
        log "initial run"
        rebuild_local_shadow
    fi
    
    find_exclusions

    if [ $SKIP_INIT_PULL == 0 ]; then
        pull_from_remote
    fi

    # After pull, we need to do a sanity check to confirm that the local
    # additions have not been clobbered by a local race condition.
    
    delete_locally
    push_from_local
    rebuild_local_shadow
    rebuild_remote_shadow    
}

################################################################################

function old_main {

    DBG="-q"
    if [ $DEBUG != 0 ]; then
       DBG="-ni"
    fi
       
    sanity_checks
    acquire_lock
    sync_machines
    release_lock

    exit 0
}

################################################################################

function status {
    # Inspect the local and remote machines to see if they are in a good state. 

    rsh test -d "$BASE/.sync"
    local remote_stat=$?

    test -d "$BASE/.sync"
    local local_stat=$?
    
    rsync -aiunO --delete --exclude=.sync/ "$BASE/" "$HOST":"$BASE" > /tmp/sync.$$
    local push_add=$(grep '^>' /tmp/sync.$$ | wc -l | tr -d ' ')
    local push_del=$(grep '^*deleting' /tmp/sync.$$ | wc -l | tr -d ' ')

    rsync -aiunO --delete --exclude=.sync/ "$HOST":"$BASE/" "$BASE"  > /tmp/sync.$$
    local pull_add=$(grep '^>' /tmp/sync.$$ | wc -l | tr -d ' ')
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

################################################################################

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

################################################################################

main $*



