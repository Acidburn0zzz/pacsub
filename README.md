PacBSD Repository Manager
=========================

This is a work in progress.

The goal is to allow easy remote control of the repository, manage user access
and have an interface to the repo-report control.

Client Side
-----------

Currently all you do on the client side is log into the server with ssh and
use the command interface presented.

Server Side
-----------

When a user logs in ssh runs the pacsub-manage command with the `--user`
parameter and reads commands and additional parameters from the original
ssh command. Note that no configuration related parameters can be changed
this way.

### Configuration

The ssh-user's `~/.config/pacsub/config` file should be set up with a
configuration. To get started a default configuration can be generated
via the `pacsub-manage config` command and then be adapted.
