# Sync

The purpose of this script is to support something like a personal Dropbox
folder.  A typical scenario will have a single remote server that serves as
ground truth for the state of a directory, while multiple clients on different
machines can then sync to the remote server, pulling down changes and pushing
up their own changes.

Goals for this solution include:

* Simplicity - Since this is designed for only a single user, we're going to
let last update win when there a conflict.

* Space efficiency - An archive should take the same space as a single copy of
the directory (with some minor overhead).

* Move / rename efficient - Reorganizing large directories of large files
should _not_ result in all content being re-transferred.

* Bi-directional - Clients should be able to handle push, pulls, and deletes.


## Notes

### Directory layout:

* local client
  * .sync
    * additions
    * deletions
    * moves
    * exclussions
    * versions
      * 0, 1
    * backup
  * regular content

* local server
  * .sync
    * lock
    * versions
      * 0, 1
    * clients
      * client -> ../versions/#
    * scripts?
      * ...
  * regular content 


### Basic Process

1. Start with the invariant that most recent version on local has an
   identical copy with the same name on the remote.  Call this version X,
   which may or may not be the most recent version on the remote.

2. If there exists a version Y > X on the remote, then the first step is to
   pull Y from the remote to the local.  We do this by pulling both X and Y
   simultaneously with deletes and hardlinks, making moves and renames very
   efficient. (pull latest remote)

3. Next, on local, create new version, Z, which starts equal to Y but has the
   changes from the local applied on top of it.  Note that this cannot be a
   normal sync operations because a normal sync would unwind many of the
   changes that resulted in X -> Y.  Instead, we look for the following:

    a. New additions on local will have a single link (and no links into X).
    
    b. New deletions on local will exist on X but not on local proper.  They
    may, however, exist in subsequent versions so we have to check the actual
    pathnames to detect a true delete.

    c. It's possible for a simultaneous delete and new addition on the same
    pathname so we need to make sure that this corner case works.

    d. Moves and renames are detected by pathname differences in X and the
    sandbox.

4. Once Z is created, we should then make Z and the local sandbox identical
   with hardlinks.  Ideally this would naver change an inode in the sandbox.

5. We should now push Y and Z to the remote.

6. On the remote, we can remove old unneeded versions and optionally rebuild
   the remote sandbox (although, a remote sandbox isn't strictly needed).

7. We can also clean up old local versions (keeping just the sandbox and Y).


## Init notes

Local states:
1. BASE does not exist
2. BASE exists, but no version
3. BASE/.sync/versions/L exists

Remote states:
1. BASE does not exist
2. BASE exist, but no version
3. BASE/.sync/versions/R exists

Local,remote state pairs:
1,1 - error message; do nothing
1,2 - init remote, pull, init local
1,3 - pull, init local (to match remote version)
2,1 - init local, push
2,2 - ask user if we should handle w/ push or pull
2,3 - pull, init local (to match remote version)
3,1 - push, init remote (to match local), sync
3,2 - init remote, push, sync
3,3 - sync

