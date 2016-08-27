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

function enter {
    read -p "<ENTER> "
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
        echo "$prefix $msg" >> "$BASE/.sync/log"
    done
}

###############################################################################

function sanity_checks {
    log "performing sanity checks"
    
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

    # TO DO: make this work relative to the state of the remote, thus allowing
    # for new locals to be incrementally added.
    
    rm -rf "$BASE/.sync"
    mkdir -p "$BASE/.sync/versions"
    log "initializing local sync"
    
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
        error "Unable to release server lock." \
              "This will undoubtedly cause problems later."
    fi
}

###############################################################################

function list_ancestors {
    while read path; do
        local dirpath=$(dirname "$path")
        while [ "$dirpath" != "$path" ]; do
            echo $dirpath
            path="$dirpath"
            dirpath=$(dirname "$path")
        done     
    done
}

###############################################################################

function find_local_updates {
    log "finding local updates"

    local lvnum=$1
    local prev="$BASE/.sync/versions/$lvnum"

    # List all file names in the local snapshot.  This will help us identify
    # additions relative to the last sync.  We don't need to note directories
    # because they will implicitly be included by the files they contain.    
    ( cd $BASE; find . -type f -not -path './.sync/*' -print ) \
        | sed 's/^\.//g' \
        > "$BASE/.sync/new"

    # List all file names from the last local version that was synced to the
    # remote.  This will help us find deletions.  We include non-files so that
    # we can test for their removal as well.
    ( cd $prev; find . -true -print ) \
        | sed 's/^\.//g' \
        > "$BASE/.sync/old"

    # Combine the two lists, sort, and strip out duplicates.
    cat "$BASE/.sync/old" "$BASE/.sync/new" | sort -u > "$BASE/.sync/all"
    
    rm -f "$BASE/.sync/additions"; touch "$BASE/.sync/additions"
    rm -f "$BASE/.sync/deletions"; touch "$BASE/.sync/deletions"    
    rm -f "$BASE/.sync/deldirs"; touch "$BASE/.sync/deldirs"    
    
    cat "$BASE/.sync/all" | (
        while read fname; do
            if [ -d "$prev/$fname" ]; then
                # This is a directory found in the previous sync ...
                if [ \! -d "$BASE/$fname" ]; then
                    # ... that appears to be deleted because it was is not in
                    # the local snapshot.
                    echo "$fname" >> "$BASE/.sync/deldirs"
                fi
                continue
            elif [ "$BASE/$fname" -ef "$prev/$fname" ]; then
                # Skip any named file in which the two versions are hardlinks
                # to the same file.
                continue
            elif [ -f "$BASE/$fname" ]; then
                # The file exists in the snapshot, but is different from the
                # last synced version, so it's a new addition.
                echo "$fname" >> "$BASE/.sync/additions"
            else
                # The file exists in the last synced version but is not in the
                # snapshot, so it was deleted.
                echo "$fname" >> "$BASE/.sync/deletions"
            fi            
        done
    )

    cp "$BASE/.sync/additions" "$BASE/.sync/inclusions"
    cat "$BASE/.sync/additions" | list_ancestors | sort -u \
         >> "$BASE/.sync/inclusions"
    
}

###############################################################################

function pull_remote_version {
    local lvnum=$1
    local rvnum=$2
    
    if [ "$rvnum" -eq "$lvnum" ]; then
        log "skipping pull because versions match"
        return
    fi

    # If versions $lvnum and $rvnum on the remote server have hardlinks
    # on the files that they have in common, then pulling over both
    # versions simultaneously (and with the -H flag) will insure that
    # moves and renames will be handled efficiently.
    
    log "pulling remote version $rvnum via local version $lvnum"
    rsync -aH \
          "$REMOTE:$BASE/.sync/versions/$lvnum" \
          "$REMOTE:$BASE/.sync/versions/$rvnum" \
          "$BASE/.sync/versions"
}

###############################################################################

function apply_remote_updates {
    local lvnum=$1
    local rvnum=$2
    local nvnum=$3

    if [  "$rvnum" -ne "$lvnum" ]; then
        # The most recent local and remote versions are different.  We've
        # already noted the local changes between the snapshot and the
        # more recent local version, so it's okay to rename the last
        # local version to the next version.        
        log "moving version $lvnum to $nvnum"
        mv "$BASE/.sync/versions/$lvnum" "$BASE/.sync/versions/$nvnum"
    fi

    # We still need to apply the last remote version's updates
    # on top of the next version.  If the condition above was true,
    # then the next command will "patch" the new version to include
    # the remote's most recent updates.  But if the condition above
    # is false, then the command above effectively does a copy
    # with hardlinks preserved.

    log "applying remote updates from version $rvnum to $nvnum"

    # In the future, I may want to log the line below if we did the
    # move above (but otherwise not).
    
    rsync -a --delete  \
          --link-dest=../../.. \
          "$BASE/.sync/versions/$rvnum/" \
          "$BASE/.sync/versions/$nvnum"
}

###############################################################################

function apply_local_updates {
    local nvnum=$1

    # Now that the next version has the last local and remote syncs
    # reconciled, we now need to apply the local snapshot updates to
    # the next version.
    
    log "applying local additions to $nvnum"    
    rsync -a \
          --exclude=.sync \
          --include-from="$BASE/.sync/inclusions" \
          --filter='-! */' \
          --exclude='*/' \
          --link-dest='../../..' \
          --log-file="$BASE/.sync/log" \
          "$BASE/" \
          "$BASE/.sync/versions/$nvnum"
    
    log "applying local deletions to $nvnum"    
    cat "$BASE/.sync/deletions" | (
        cd "$BASE/.sync/versions/$nvnum"
        while read line; do
            log "deleting ./$line"
            /bin/rm -f "./$line"
        done
    )

    cat "$BASE/.sync/deldirs" | (
        cd "$BASE/.sync/versions/$nvnum"
        while read line; do
            log "deleting directory ./$line"
            /bin/rm -rf "./$line"
        done
    )
    
    # This next rsync will then make the local snapshot match the
    # next version.
    
    log "Merging next version $nvnum into local snapshot"
    rsync -aq --delete \
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
    
    rsync -aH \
          --delete-after \
          "$BASE/.sync/versions/$rvnum" \
          "$BASE/.sync/versions/$nvnum" \
          "$REMOTE:$BASE/.sync/versions"

    rsh rm -f "$BASE/.sync/clients/$LOCAL"

    rsh ln -s "../versions/$nvnum" "$BASE/.sync/clients/$LOCAL"

    log "Merging next version $nvnum into remote snapshot"
    
    rsh rsync -a --delete \
        --exclude=.sync \
        --link-dest=../../.. \
        "$BASE/.sync/versions/$nvnum/" "$BASE" \
        >> "$BASE/.sync/log"
    
    # TO DO: have remote code to garbage collect versions    
}

###############################################################################

function sync {
    sanity_checks
    local lvnum=$(ls "$BASE/.sync/versions" | sort -rn | head -1)
    local rvnum=$(rsh ls "$BASE/.sync/versions" | sort -rn | head -1)
    find_local_updates $lvnum
    enter
    acquire_lock
    pull_remote_version $lvnum $rvnum    
    local nvnum=$(($rvnum + 1))
    enter
    apply_remote_updates $lvnum $rvnum  $nvnum
    enter
    apply_local_updates $nvnum
    enter
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

# if there remote and local are the same and there are no updaes, there
# shouldn't be an version bump.
