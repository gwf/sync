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

Directory layout:

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


