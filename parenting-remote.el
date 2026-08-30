;;; parenting-remote.el --- Children on other machines -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Spawn parenting children on other machines: ssh-reachable hosts,
;; VMs (typically through a forwarded ssh port), TRAMP-style specs.
;;
;; The transport reuses the local design unchanged.  The parent
;; listens on a private local Unix socket, exactly as for a local
;; child, and ssh forwards a Unix socket on the child's machine back
;; to it (-R).  The child connects to that socket and cannot tell it
;; is remote, so everything — batch/daemon/visible modes, async
;; tasks, the sandbox, the inert-data check — behaves identically,
;; and the child side needs no network listener, no open port, and
;; no code changes.  TRAMP is used only for file plumbing: making a
;; private scratch directory on the remote machine and staging the
;; parenting sources into it.
;;
;; Why not run the protocol over the ssh channel's own stdio?  A
;; --batch Emacs can only read its stdin with a blocking getchar
;; loop, during which timers and process sentinels never run, so
;; asynchronous tasks would starve.  Forwarding a socket keeps the
;; child fully asynchronous for free.  It also keeps the wire off
;; ptys and remote shells; only the bootstrap command line crosses
;; the remote shell, shell-quoted.
;;
;; Non-ssh TRAMP methods (sudo, docker, ...) are not supported yet:
;; they offer no socket forwarding, so they need a small relay
;; process on the far side.  `:ssh-command' and `:remote-prefix' are
;; where that relay command would be wired in.

;;; Code:

(require 'parenting)
(require 'parenting-parent)
(require 'cl-lib)
(eval-when-compile (require 'tramp))

(defconst parenting-remote--ssh-methods '("ssh" "sshx" "scp" "scpx")
  "TRAMP methods that a plain ssh client can reach directly.")

(defun parenting-remote--parse-host (host)
  "Parse HOST into a list (DESTINATION SSH-ARGS TRAMP-PREFIX).
HOST is either an ssh destination — \"host\" or \"user@host\",
optionally ending in \"#PORT\" — or a single-hop ssh-method TRAMP
file name prefix such as \"/ssh:user@host#2222:\".  DESTINATION is
the argument for the ssh command line, SSH-ARGS are extra arguments
it needs (the port), and TRAMP-PREFIX is the remote identification
for file operations on that machine."
  (if (string-prefix-p "/" host)
      (progn
        (require 'tramp)
        (let* ((vec (tramp-dissect-file-name host))
               (method (tramp-file-name-method vec))
               (user (tramp-file-name-user vec))
               (machine (tramp-file-name-host vec))
               (port (tramp-file-name-port vec)))
          (unless (member method parenting-remote--ssh-methods)
            (error "TRAMP method %s is not reachable by ssh" method))
          (when (tramp-file-name-hop vec)
            (error "Multi-hop TRAMP names are not supported; %s"
                   "pass an :ssh-command with -J instead"))
          (list (if user (format "%s@%s" user machine) machine)
                (and port (list "-p" (format "%s" port)))
                (file-remote-p host))))
    (let* ((port (and (string-match "#\\([0-9]+\\)\\'" host)
                      (match-string 1 host)))
           (destination (if port
                            (substring host 0 (match-beginning 0))
                          host)))
      (list destination
            (and port (list "-p" port))
            (format "/ssh:%s:" host)))))

(defun parenting-remote--local-name (path)
  "Return PATH as the machine holding it sees it."
  (or (file-remote-p path 'localname) path))

(defun parenting-remote--make-scratch-directory (prefix)
  "Create a private scratch directory on the machine PREFIX names."
  (let* ((default-directory (concat prefix "/"))
         (directory (make-nearby-temp-file "parenting-" t)))
    (set-file-modes directory #o700)
    directory))

(defun parenting-remote--stage-sources (directory)
  "Copy into DIRECTORY the parenting sources for the child bootstrap.
DIRECTORY is a possibly remote scratch directory.  Only the .el
files travel, matching the bootstrap's version-skew rule: the child
must never load byte-code compiled by the parent's Emacs."
  (let ((source (parenting--child-library-directory)))
    (dolist (base '("parenting" "parenting-child"))
      (copy-file (expand-file-name (concat base ".el") source)
                 (file-name-as-directory directory)))))

(defun parenting-remote--display-method (forward-display)
  "Normalize FORWARD-DISPLAY to nil, `x11', or `wayland'.
t picks by the parent's own session type."
  (pcase forward-display
    ('nil nil)
    ('x11 'x11)
    ('wayland 'wayland)
    ('t (if (getenv "WAYLAND_DISPLAY") 'wayland 'x11))
    (other (error "Unknown :forward-display %S" other))))

(defun parenting-remote--default-ssh-command (port-args display)
  "Return the ssh invocation for PORT-ARGS and DISPLAY forwarding.
DISPLAY is nil, `x11' (ssh's own X forwarding), or `wayland'
\(waypipe wrapping ssh)."
  (append (and (eq display 'wayland) '("waypipe"))
          (list "ssh")
          port-args
          (and (eq display 'x11) '("-X"))))

(defun parenting-remote--wrapper (ssh-command destination
                                              remote-socket local-socket)
  "Return a command wrapper launching children through ssh.
The wrapper appends to SSH-COMMAND the reverse forwarding of
REMOTE-SOCKET to LOCAL-SOCKET, DESTINATION, and the child's command
line shell-quoted, since ssh hands it to the remote shell as a
single string."
  (lambda (command)
    (append ssh-command
            (list "-R" (concat remote-socket ":" local-socket))
            (list destination)
            (mapcar #'shell-quote-argument command))))

;;;###autoload
(cl-defun parenting-spawn-remote (host &key (emacs "emacs") args
                                       ((:load-path extra-load-path)) init
                                       daemon
                                       (batch (not daemon))
                                       (quick t)
                                       forward-display
                                       child-library-directory
                                       ssh-command
                                       remote-prefix
                                       name
                                       (timeout parenting-default-timeout))
  "Spawn a child Emacs on HOST and return a connection to it.
HOST is an ssh destination (\"host\", \"user@host\", optionally
with \"#PORT\") or an equivalent single-hop TRAMP prefix like
\"/ssh:user@host#2222:\".  A VM is just a HOST too, typically
through its forwarded ssh port (\"root@localhost#2222\").

EMACS is the binary to run on HOST, resolved there (default
\"emacs\"); pass a store path or absolute path for a specific
build.  ARGS, :LOAD-PATH, INIT, DAEMON, BATCH, QUICK, NAME, and
TIMEOUT mean what they do in `parenting-spawn', with paths
understood on HOST.  FORWARD-DISPLAY forwards this machine's
display over the connection, so a visible-frame child — or a daemon
child later promoted with a `make-frame' form — opens its frame
here: `x11' uses ssh's own X forwarding (-X), `wayland' wraps ssh
in waypipe, and t picks by the parent's session type.  The remote
Emacs must be built for the chosen protocol, and `wayland' needs
waypipe installed on both ends.

CHILD-LIBRARY-DIRECTORY is a directory on HOST already holding the
parenting sources (say, a nix store path present there); by default
they are staged into a private scratch directory over TRAMP.
SSH-COMMAND overrides the ssh invocation (a list of strings,
e.g. (\"ssh\" \"-J\" \"bastion\")); port and display-forwarding
arguments are then the caller's business.  REMOTE-PREFIX overrides the TRAMP
prefix used for file operations on HOST.

The connection works exactly like a local one; `parenting-shutdown'
additionally removes the remote scratch directory.  Requires
OpenSSH with Unix-socket forwarding (client and server ≥ 6.7) and
`AllowStreamLocalForwarding' not disabled on HOST."
  (pcase-let* ((`(,destination ,port-args ,default-prefix)
                (parenting-remote--parse-host host))
               (prefix (or remote-prefix default-prefix))
               (ssh (or ssh-command
                        (parenting-remote--default-ssh-command
                         port-args
                         (parenting-remote--display-method
                          forward-display)))))
    (let ((remote-directory nil)
          (local-directory nil)
          (conn nil))
      (unwind-protect
          (progn
            (setq remote-directory
                  (parenting-remote--make-scratch-directory prefix))
            (setq local-directory (parenting--make-socket-directory))
            (let* ((library-directory
                    (or child-library-directory
                        (progn
                          (parenting-remote--stage-sources remote-directory)
                          (parenting-remote--local-name remote-directory))))
                   (remote-socket
                    (concat (file-name-as-directory
                             (parenting-remote--local-name remote-directory))
                            "socket"))
                   (local-socket
                    (expand-file-name "socket" local-directory)))
              (setq conn (parenting-spawn
                          :emacs emacs
                          :args args
                          :load-path extra-load-path
                          :init init
                          :daemon daemon
                          :batch batch
                          :quick quick
                          :command-wrapper (parenting-remote--wrapper
                                            ssh destination
                                            remote-socket local-socket)
                          :socket-path local-socket
                          :child-socket-path remote-socket
                          :child-library-directory library-directory
                          :name (or name (concat "parenting-" destination))
                          :timeout timeout))
              (setf (parenting-connection-socket-directory conn)
                    local-directory)
              (setf (parenting-connection-remote-directory conn)
                    remote-directory)
              conn))
        (unless conn
          (when (and local-directory (file-directory-p local-directory))
            (ignore-errors (delete-directory local-directory t)))
          (when remote-directory
            (ignore-errors
              (with-timeout (10 nil)
                (when (file-directory-p remote-directory)
                  (delete-directory remote-directory t))))))))))

(provide 'parenting-remote)
;;; parenting-remote.el ends here
