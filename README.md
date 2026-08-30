# parenting

Remote-control one Emacs (the child) from another (the parent) over a
private Unix domain socket.

- The parent has unrestricted evaluation in the child:
  `parenting-eval` sends any form and returns the deserialized result.
- The child may only run code in the parent through a sandbox: an
  explicit per-connection allowlist of functions, each optionally
  gated by a predicate over the argument list, plus cross-cutting
  guard functions. Direction is enforced structurally: a parent-side
  connection has no handler for `eval` requests, so a child cannot
  evaluate forms in the parent at all.

Use cases: testing new Emacs versions (point `parenting-spawn` at any
Emacs binary and drive it), remote-controlling a sandboxed Emacs
process, and managing children on other machines — ssh hosts, VMs,
TRAMP-style specs (`parenting-spawn-remote`).

Requires Emacs 26.1 or later. No other dependencies; remote children
additionally need OpenSSH on both ends (see below).

## Installing

Four files: `parenting.el` (the protocol), `parenting-parent.el`,
`parenting-child.el`, and `parenting-remote.el`. Not on MELPA yet. The
version is pre-1.0: the API described here is stable in intent, but
names and signatures may still change before 1.0.

On Emacs 30 or later, `use-package` fetches and installs it:

```elisp
(use-package parenting
  :vc (:url "https://github.com/clhodapp/parenting" :rev :newest)
  :commands (parenting-spawn parenting-listen parenting-spawn-remote
             parenting-child-connect parenting-child-start))
```

On Emacs 29, `package-vc-install` does the same fetch as a one-off
(`package-vc-upgrade` pulls later commits), and the `use-package` block
above works without its `:vc` line:

```elisp
(package-vc-install "https://github.com/clhodapp/parenting")
```

With straight.el (elpaca accepts the same recipe form):

```elisp
(straight-use-package
 '(parenting :type git :host github :repo "clhodapp/parenting"))
```

Or clone it, add the directory to `load-path`, and `require` the side
you need (`parenting-parent`, `parenting-child`, `parenting-remote`).
The child bootstrap needs the `.el` sources next to whatever is loaded
(it loads them by exact file name), which every route above provides.

## Parent side (`parenting-parent`)

```elisp
;; Spawn a batch child running some other Emacs build:
(setq conn (parenting-spawn :emacs "/path/to/emacs-31/bin/emacs"))
(parenting-peer-emacs-version conn)     ;; => "31.0.50"
(parenting-eval conn '(+ 1 2))          ;; => 3
(parenting-eval-async conn 'features (lambda (v) (message "%S" v)))

;; Sandbox: what the child may call back into this Emacs:
(parenting-allow-function conn 'message)
(parenting-allow-function conn 'expt (lambda (args) (< (car args) 10)))
(parenting-add-guard conn (lambda (_fn args) (not (memq :secret args))))

(parenting-shutdown conn)
```

`parenting-spawn` keywords: `:emacs` (binary, defaults to the running
one), `:batch`/`:daemon` (see below), `:quick` (default t; nil drops
-Q so the child runs its normal init), `:args`, `:load-path`, `:init`
(form evaluated in the child right after connecting), `:name`,
`:timeout`.

### Child modes: visible, headless, headless-but-interactive

- `:batch t` (the default) — headless `--batch` child. Cheap, but a
  degenerate Emacs: no redisplay, no frames, `noninteractive` is t.
  Right for protocol-level and pure-elisp work.
- `:daemon t` — headless `--fg-daemon` child: a *full interactive*
  Emacs (event loop, timers, frame machinery, real init with
  `:quick nil`) with no visible frame. Right for driving a new build
  off-screen. Promote it to visible later by evaluating a
  `make-frame` form in it.
- both nil — the child starts normally and opens a frame on the
  parent's display: trying the new build as a user, or watching a
  sandboxed agent's Emacs.

For true-GUI rendering off-screen, combine `:command-wrapper` with
something like `xvfb-run` or a headless Wayland compositor.

The child bootstraps by loading the parenting `.el` sources by exact
file name — never `.elc` — so the child can be a different Emacs
version than the parent without picking up incompatible byte-code.
Testing a fresh nix build is just:

```elisp
(parenting-spawn :emacs "./result/bin/emacs")
```

For children that must run inside a sandbox (e.g. an Emacs-hosted
LLM agent under bwrap), three more keywords wrap the command:

```elisp
(parenting-spawn
 :command-wrapper '("bwrap" "--ro-bind" "/nix/store" "/nix/store"
                    "--bind" "/tmp/agent" "/tmp/agent" ...)
 :socket-path "/tmp/agent/ctl.sock"        ; where the parent listens
 :child-socket-path "/tmp/agent/ctl.sock"  ; same path inside the ns
 :child-library-directory "/path/visible/inside/the/sandbox")
```

`:command-wrapper` is prefixed to the child's command line;
`:socket-path` makes the parent listen at a caller-owned path (its
directory then survives `parenting-shutdown`); `:child-socket-path`
is the socket's path as seen from inside the child's mount namespace
when that differs; `:child-library-directory` points the child at a
copy of the parenting sources it can actually read.

To attach an existing Emacs instead of spawning one, call
`(parenting-listen)` in the parent, hand its
`parenting-server-socket-path` to the child, and run
`(parenting-child-connect PATH)` there. An attached child survives
the parent; a *spawned* child is owned by its parent and exits when
the connection closes, whatever machine it runs on.

## Remote children (`parenting-remote`): ssh hosts, VMs, TRAMP

`parenting-spawn-remote` spawns the child on another machine:

```elisp
(parenting-spawn-remote "user@host")               ; ssh destination
(parenting-spawn-remote "root@localhost#2222")     ; a VM's forwarded port
(parenting-spawn-remote "/ssh:user@host#2222:")    ; TRAMP-style spec
(parenting-spawn-remote "build-vm"
 :emacs "/nix/store/...-emacs-31/bin/emacs"        ; resolved on the host
 :child-library-directory "/nix/store/...-parenting/...")
```

The transport reuses the local design unchanged: the parent listens
on a private local Unix socket exactly as for a local child, and ssh
reverse-forwards (`-R`) a socket on the child's machine back to it.
The child connects to a Unix socket like always and cannot tell it is
remote, so every mode and feature — batch/daemon/visible, async
tasks, polling, the sandbox, the inert-data check — behaves
identically, and the child machine needs no open port and no listener.
TRAMP is used only for file plumbing: creating a private (0700)
scratch directory on the host and staging `parenting.el` /
`parenting-child.el` into it, so the usual bootstrap-from-source rule
holds across machines and Emacs versions. Pass
`:child-library-directory` (e.g. a nix store path present on the
host) to skip the staging. `parenting-shutdown` also removes the
remote scratch directory.

Keywords: everything `parenting-spawn` takes that makes sense
remotely (`:emacs`, defaulting to `"emacs"` on the host's PATH,
`:args`, `:load-path`, `:init`, `:batch`/`:daemon`, `:quick`,
`:name`, `:timeout` — paths understood on the host), plus:

- `:forward-display` — forward the parent's display over the
  connection so a visible-frame child (`:batch nil :daemon nil`), or
  a `:daemon` child later promoted with a `make-frame` form, opens
  its frame *locally*, on the parent's display — same story as for
  local children, just with the frame contents coming over the wire.
  `'wayland` wraps ssh in waypipe (waypipe needed on both ends, pgtk
  Emacs on the host), `'x11` uses ssh's own `-X` (X-capable Emacs on
  the host), and `t` picks by the parent's session type.
- `:ssh-command` — override the ssh invocation, e.g.
  `'("ssh" "-J" "bastion")` for jump hosts or `'("waypipe" "ssh")`;
  port and X arguments are then the caller's business.
- `:remote-prefix` — override the TRAMP prefix used for the file
  plumbing, when it differs from what the host spec implies.

`parenting-with-child` accepts `:host` and routes to
`parenting-spawn-remote`, so the test-fixture / version-matrix story
extends across machines:

```elisp
(parenting-with-child (conn :host "root@localhost#2222"
                            :emacs "./result/bin/emacs")
  (should (parenting-eval conn '(fboundp 'seq-map))))
```

A VM is just a host: boot it with an ssh port forward (the usual
QEMU/NixOS test setup) and point `:host` at it.

Requirements: OpenSSH ≥ 6.7 on both ends (Unix-socket forwarding),
`AllowStreamLocalForwarding` not disabled on the host, and key/agent
auth (the TRAMP side can prompt; the transport ssh cannot). Failures
surface as `parenting-timeout` with the ssh stderr tail attached.

Design notes. The protocol deliberately does *not* run over the ssh
channel's stdio: a `--batch` Emacs can only read its own stdin with a
blocking getchar loop, during which timers and process sentinels
never run, so async tasks would starve — socket forwarding keeps the
child fully asynchronous with zero child-side changes. It also keeps
the wire off ptys and remote shells; only the bootstrap command line
crosses the remote shell (shell-quoted — ssh joins the words with
spaces for the remote shell to re-split), and the wire format escapes
control characters so even a mangling transport can't corrupt string
payloads mid-message. Non-ssh TRAMP methods (`/sudo:`, `/docker:`)
are not supported yet: they have no socket forwarding, so they need a
small relay (e.g. socat) on the far side — `:ssh-command` and
`:remote-prefix` are where that relay command will be wired in.

Threat-model addendum: the wire inherits ssh's authentication and
encryption; the remote socket lives in a 0700 scratch directory, so
other users on the child's machine cannot connect to it; and the
parent-side sandbox already assumes a compromised child, which now
includes a compromised child *machine*.

## Child side (`parenting-child`)

```elisp
(parenting-call-parent 'message '("hi from the child"))
```

Calls are rejected with `parenting-forbidden` unless the parent
allowlisted the function and every predicate/guard approves.

## Asynchronous tasks in the child

`parenting-eval` runs in the child's main loop, so a long tool call
(shell, build) would block that Emacs while it runs. Tasks don't:
the child acks immediately, evaluates the form with
`parenting-current-task` bound to a handle, and the form arranges
completion later from a sentinel or timer:

```elisp
(parenting-start-task
 conn
 '(let ((task parenting-current-task))
    (parenting-task-on-cancel task (lambda () (kill-process proc)))
    (make-process
     :name "build" :command '("make" "-C" "/tmp/proj")
     :sentinel (lambda (proc _event)
                 (unless (process-live-p proc)
                   (parenting-task-finish task (process-exit-status proc))))))
 (lambda (status) (message "build finished: %S" status))
 (lambda (symbol data) (message "build failed: %S %S" symbol data)))
```

`parenting-run-task` is the synchronous variant (the parent blocks,
the child stays responsive; on timeout the task is cancelled in the
child). `parenting-cancel-task` cancels by id; the child runs the
task's `parenting-task-on-cancel` function and late completions are
ignored on both sides. If the task form itself signals during its
initial evaluation, the task fails immediately. Disconnects fail all
outstanding tasks with `parenting-closed`.

### Polled tasks and backpressure

Callback consumers are event-driven, but poll-shaped consumers (an
MCP bridge answering "is task 42 done yet?") need results *retained*
until claimed. Start a task with no callback and it becomes polled:

```elisp
(setq id (parenting-start-task conn '(...)))   ; no callback: polled
(parenting-poll-task conn id)      ; running / settled (claims) / nil
(parenting-drain-task-results conn) ; claim everything, oldest first
(parenting-task-load conn)  ; (:outstanding N :unclaimed M :capacity C)
```

Cancelled and disconnect-orphaned polled tasks settle as claimable
`parenting-cancelled` / `parenting-closed` errors, so a poller
always learns the fate of a task it started.

Design note on the data structures. Three different retention
problems get three different answers:

- *Live tracking* (callbacks for tasks in flight) is a hash table:
  it must never drop an entry — a ring at capacity would evict live
  completions and hang their waiters — and it is naturally bounded
  by genuinely outstanding work.
- *Unclaimed polled results* are a bounded ring
  (`parenting-task-results-size', default 256): the poller may be
  slow, dead, or disconnected, and an unbounded mailbox is a leak.
  Bulk data stays out of the hot path; the ring holds the settled
  result plists themselves. Rather than ever relying on eviction,
  backpressure is applied at the *submitters*: starting a polled
  task past capacity signals `parenting-backpressure', so the
  submitter queues and retries after claiming — check
  `parenting-task-load' to stay ahead of it. Eviction remains as a
  last-ditch safety valve and is recorded in the event history.
- *The debugging log* is a lossy ring by design:
  `parenting-task-events' returns the last
  `parenting-task-history-size' task events (started / finished /
  failed / cancelled / evicted, with timestamps) per connection.

## Threat model: autonomous agents in (or wired to) children

The intended end state includes auto-running LLM agents whose code
executes in a child — either the agent itself lives in the child, or
a parent-resident agent has its tool calls routed into a child via
`parenting-eval`. Either way the parent must assume the child is
fully compromised. The layers, outermost first:

1. OS-level isolation of the child process (`:command-wrapper`,
   e.g. bwrap) bounds what the child can touch directly.
2. The parent structurally refuses `eval` requests — a child cannot
   evaluate forms in the parent at all.
3. The allowlist defaults to deny-all; each grant can carry an
   argument predicate, and guards see every call. Predicates and
   guards run in the parent, so they may consult state the child
   cannot see — or prompt the human (`y-or-n-p`) before allowing.
4. Incoming messages are checked to contain only inert data
   (numbers, symbols, strings, conses, vectors, records, hash
   tables). A peer that smuggles callable objects — say a `#[...]`
   byte-code literal into the args of an allowlisted higher-order
   function — is disconnected on the spot.

Remaining care points for allowlist authors: a granted function runs
with the parent's full privileges, so prefer purpose-built narrow
functions over general ones, and remember that symbols in args are
data until something applies them.

## As a test harness

Parenting doubles as an ERT fixture: `parenting-with-child` gives
each test a hermetic, disposable, *real* Emacs, so tests can't leak
state into each other or the runner, and code under test can crash
its Emacs without killing the suite. This package's own suite is
built on it.

```elisp
(ert-deftest my-package-works ()
  (parenting-with-child (conn :load-path (list my-package-dir))
    (should (equal 'ok (parenting-eval
                        conn '(progn (require 'my-package)
                                     (my-package-self-check)))))))

;; Version matrix: same assertions against several builds.
(dolist (emacs '("/run/current-system/sw/bin/emacs"
                 "./result/bin/emacs"))
  (parenting-with-child (conn :emacs emacs)
    (should (parenting-eval conn '(fboundp 'seq-map)))))
```

## Wire format

Messages are plists printed with `prin1` (`print-circle` on) and read
back with `read`. Before printing, values are recursively copied with
unreadable objects (buffers, windows, processes, ...) replaced by
their printed representation as strings, so every result
deserializes; cycles and shared structure are preserved. Errors on
either side travel as `(:error-symbol SYM :error-data DATA)` and are
re-signaled as `parenting-remote-error`.

## Development

`make` byte-compiles with warnings as errors and runs the ERT suite
(`test/parenting-test.el`); `make test` runs the suite alone. Every
test spawns a real child Emacs, the same binary that runs the suite,
and drives it over the socket. CI runs both on Emacs 29.4, 30.1, 31.1,
and the current development snapshot.

## License

MIT. See `LICENSE`.
