# Process Manager

Build with `make` or build and open a standalone window with `make run`.
The project uses the same local ellipse checkout and Alatar theme as systemdui.

The chart button in the Alatar bar opens a Wayland layer-shell menu under
the button. Click it again, select Close, or press Esc to dismiss it.

Search by process name, PID, or command line. Filters keep ancestors visible
so matches retain their place in the tree. Column headers sort roots and
siblings independently. CPU percentage is sampled once per second and
100% represents one fully used logical CPU.

Each row offers process details. Signal actions require confirmation.
Terminate sends SIGTERM, Kill -9 sends SIGKILL, and Suspend and Resume send
SIGSTOP and SIGCONT. Pkill by name sends SIGTERM to your processes with
the same exact kernel process name. Signal delivery uses Linux PID file
descriptors so an exited process cannot redirect a signal to a reused PID.
