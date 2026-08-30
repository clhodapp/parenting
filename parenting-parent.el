;;; parenting-parent.el --- Parent side of parenting -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Parent-side API of the parenting parent-child Emacs system.
;;
;; Spawn a child Emacs (any binary, e.g. a build you are testing) with
;; `parenting-spawn', or call `parenting-listen' and have an existing
;; Emacs attach with `parenting-child-connect'.  Evaluate forms in the
;; child with `parenting-eval' / `parenting-eval-async'; results come
;; back as readable Lisp values, with unreadable objects replaced by
;; their printed representation as strings.
;;
;; The child may only run code in the parent through the sandbox:
;; grant individual functions with `parenting-allow-function' (with an
;; optional predicate over the argument list) and add cross-cutting
;; checks with `parenting-add-guard'.  Everything else is rejected.

;;; Code:

(require 'parenting)
(require 'cl-lib)
(require 'ring)

(defcustom parenting-default-allowed-functions nil
  "Alist of (FUNCTION . PREDICATE) copied to each new connection.
PREDICATE is either t, allowing all calls to FUNCTION, or a function
that receives the list of arguments and returns non-nil to allow the
call.  This seeds the per-connection allowlist consulted when a
child asks the parent to run a function; see
`parenting-allow-function'."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'parenting)

(defcustom parenting-default-guard-functions nil
  "List of guard functions copied to each new connection.
Each is called with the requested function and its argument list
whenever a child asks the parent to run a function; if any returns
nil the call is rejected even if the function is allowlisted."
  :type '(repeat function)
  :group 'parenting)

(defvar parenting-connections nil
  "Live connections from this (parent) Emacs to child Emacsen.")

;;; Sandbox

(defun parenting-allow-function (conn fn &optional predicate)
  "Allow the child on CONN to call FN in this Emacs.
PREDICATE, if non-nil, is called with the list of arguments the
child supplied and must return non-nil for the call to proceed."
  (setf (alist-get fn (parenting-connection-allowed-functions conn))
        (or predicate t)))

(defun parenting-disallow-function (conn fn)
  "Remove FN from the set of functions the child on CONN may call."
  (setf (alist-get fn (parenting-connection-allowed-functions conn)
                   nil 'remove)
        nil))

(defun parenting-add-guard (conn guard)
  "Require GUARD to approve every call made by the child on CONN.
GUARD is called with the requested function and its argument list
and must return non-nil for the call to proceed."
  (push guard (parenting-connection-guard-functions conn)))

(defun parenting--check-call (conn fn args)
  "Signal `parenting-forbidden' unless CONN's child may apply FN to ARGS."
  (let ((entry (assq fn (parenting-connection-allowed-functions conn))))
    (unless entry
      (signal 'parenting-forbidden
              (list fn "function is not on the allowlist")))
    (let ((predicate (cdr entry)))
      (unless (or (eq predicate t) (funcall predicate args))
        (signal 'parenting-forbidden
                (list fn "arguments rejected by the predicate"))))
    (dolist (guard (parenting-connection-guard-functions conn))
      (unless (funcall guard fn args)
        (signal 'parenting-forbidden
                (list fn "call rejected by a guard function"))))))

(defun parenting--handle-call (conn message)
  "Apply the sandboxed call in MESSAGE from CONN's child."
  (let ((fn (plist-get message :fn))
        (args (plist-get message :args)))
    (parenting--check-call conn fn args)
    (apply fn args)))

(setf (alist-get '(parent . call) parenting--request-handlers
                 nil nil #'equal)
      #'parenting--handle-call)

;;; Connection bookkeeping

(defun parenting--register-connection (conn)
  "Give CONN the default sandbox and track it in `parenting-connections'."
  (setf (parenting-connection-allowed-functions conn)
        (copy-alist parenting-default-allowed-functions))
  (setf (parenting-connection-guard-functions conn)
        (copy-sequence parenting-default-guard-functions))
  (push conn parenting-connections)
  conn)

(defun parenting--unregister-connection (conn)
  "Drop CONN from `parenting-connections'."
  (setq parenting-connections (delq conn parenting-connections)))

(add-hook 'parenting-connection-close-functions
          #'parenting--unregister-connection)

;;; Listening for children

(defun parenting--make-socket-directory ()
  "Create and return a fresh private directory for a control socket."
  (let ((directory (make-temp-file "parenting-" t)))
    (set-file-modes directory #o700)
    directory))

(defun parenting--server-log (server client _message)
  "Adopt CLIENT, a new child connection accepted by SERVER."
  (let ((conn (parenting--setup-connection client 'parent))
        (on-connect (process-get server 'parenting-on-connect)))
    (parenting--register-connection conn)
    (process-put server 'parenting-last-connection conn)
    (when on-connect
      (funcall on-connect conn))))

;;;###autoload
(cl-defun parenting-listen (&key path on-connect (name "parenting-server"))
  "Listen for child Emacsen and return the server process.
PATH is the Unix socket to listen on; by default a fresh socket is
created in a private directory.  Ask for it with
`parenting-server-socket-path' and pass it to
`parenting-child-connect' in the child.  ON-CONNECT, if non-nil, is
called with each new connection, which is also pushed onto
`parenting-connections'.  NAME names the server process."
  (let* ((directory (and (null path) (parenting--make-socket-directory)))
         (socket (or path (expand-file-name "socket" directory)))
         (server (make-network-process
                  :name name
                  :server t
                  :family 'local
                  :service socket
                  :noquery t
                  :log #'parenting--server-log)))
    (process-put server 'parenting-socket-path socket)
    (process-put server 'parenting-socket-directory directory)
    (process-put server 'parenting-on-connect on-connect)
    server))

(defun parenting-server-socket-path (server)
  "Return the socket path a `parenting-listen' SERVER listens on."
  (process-get server 'parenting-socket-path))

(defun parenting-stop-server (server)
  "Stop SERVER and remove its socket directory if it owns one."
  (let ((directory (process-get server 'parenting-socket-directory)))
    (when (process-live-p server)
      (delete-process server))
    (when (and directory (file-directory-p directory))
      (delete-directory directory t))))

;;; Spawning children

(defun parenting--child-library-directory ()
  "Return the directory the child must add to its `load-path'."
  (let ((library (locate-library "parenting-child")))
    (unless library
      (error "Cannot locate parenting-child for the child's load-path"))
    (file-name-directory library)))

(defun parenting--child-bootstrap (directory verified socket)
  "Return the --eval form string that bootstraps the child.
The child loads the parenting .el sources out of DIRECTORY by exact
file name, never byte-code, so a child built by a different Emacs
version (say, a fresh nix result link) cannot pick up incompatible
.elc files compiled by this Emacs.  When VERIFIED is non-nil the
files must be readable from this process; pass nil when DIRECTORY is
only visible inside the child's sandbox.  SOCKET is the socket path
as the child sees it."
  (concat
   "(progn "
   (mapconcat (lambda (base)
                (let ((file (expand-file-name (concat base ".el")
                                              directory)))
                  (when (and verified (not (file-readable-p file)))
                    (error "Missing parenting source file: %s" file))
                  (format "(load %S nil t t)" file)))
              '("parenting" "parenting-child")
              " ")
   (format " (parenting-child-start %S))" socket)))

(defun parenting--stderr-tail (buffer)
  "Return up to the last 2000 characters of BUFFER, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (buffer-substring-no-properties
       (max (point-min) (- (point-max) 2000))
       (point-max)))))

;;;###autoload
(cl-defun parenting-spawn (&key emacs args ((:load-path extra-load-path)) init
                                daemon
                                (batch (not daemon))
                                (quick t)
                                command-wrapper
                                socket-path
                                child-socket-path
                                child-library-directory
                                (name "parenting-child")
                                (timeout parenting-default-timeout))
  "Spawn a child Emacs and return a connection to it.
EMACS is the Emacs binary to run; it defaults to the running one, so
point it at a different build (a nix result link, say) to test a new
Emacs version.  ARGS are extra command-line arguments inserted after
-Q.  :LOAD-PATH lists extra directories for the child's load path.
INIT, if non-nil, is a form evaluated in the child right after it
connects.  Three keywords pick the child's mode: with BATCH non-nil
\(the default) the child runs with --batch and serves until the
connection closes; with DAEMON non-nil it runs with --fg-daemon
instead — a full interactive Emacs with no visible frame, which you
can promote later by evaluating a `make-frame' form in it; with both
nil the child starts normally and shows a frame on the parent's
display.  With QUICK nil, -Q is dropped so the child starts with its
normal init files.  NAME names the child process.  Signal
`parenting-timeout' if the child has not connected after TIMEOUT
seconds.

The remaining keywords exist for launching the child inside a
sandbox or on another machine.  COMMAND-WRAPPER is either a list of
strings prefixed to the child's command line (e.g. a bwrap or
systemd-run invocation) or a function that receives the child's
command line, a list of strings, and returns the full command to
run — for launchers that must also transform the arguments, the way
ssh needs them shell-quoted.  SOCKET-PATH is where this Emacs
listens instead of a fresh private socket; its directory then
belongs to the caller and survives `parenting-shutdown'.
CHILD-SOCKET-PATH is the same socket as seen from where the child
runs (another mount namespace, or another machine entirely), when
that differs.  CHILD-LIBRARY-DIRECTORY is where the child finds the
parenting .el sources, when the parent's copy is not visible to it."
  (when (and batch daemon)
    (error "Choose at most one of :batch and :daemon"))
  (let* ((emacs (or emacs (expand-file-name invocation-name
                                            invocation-directory)))
         (directory (and (null socket-path)
                         (parenting--make-socket-directory)))
         (socket (or socket-path (expand-file-name "socket" directory)))
         (server (make-network-process
                  :name (concat name "-server")
                  :server t
                  :family 'local
                  :service socket
                  :noquery t
                  :log #'parenting--server-log))
         (stderr (generate-new-buffer (format " *%s-stderr*" name)))
         (library-directory (or child-library-directory
                                (parenting--child-library-directory)))
         (child-command (append
                         (list emacs)
                         (and quick '("-Q"))
                         (and batch '("--batch"))
                         (and daemon '("--fg-daemon"))
                         args
                         (cl-mapcan (lambda (dir) (list "-L" dir))
                                    extra-load-path)
                         (list "--eval"
                               (parenting--child-bootstrap
                                library-directory
                                (null child-library-directory)
                                (or child-socket-path socket)))))
         (command (if (functionp command-wrapper)
                      (funcall command-wrapper child-command)
                    (append command-wrapper child-command)))
         (child (make-process :name name
                              :command command
                              :noquery t
                              :stderr stderr))
         (deadline (+ (float-time) timeout))
         (conn nil))
    (let ((pipe (get-buffer-process stderr)))
      (when pipe
        (set-process-query-on-exit-flag pipe nil)))
    (unwind-protect
        (progn
          ;; Wait for the child to connect and say hello.
          (while (and (process-live-p child)
                      (or (null conn)
                          (null (parenting-connection-peer-info conn)))
                      (<= (float-time) deadline))
            (accept-process-output nil 0.05)
            (unless conn
              (setq conn (process-get server 'parenting-last-connection))))
          (unless (process-live-p child)
            (error "Child Emacs exited during startup: %s"
                   (or (parenting--stderr-tail stderr) "")))
          (when (or (null conn)
                    (null (parenting-connection-peer-info conn)))
            (signal 'parenting-timeout
                    (list "child did not connect"
                          (parenting--stderr-tail stderr))))
          (setf (parenting-connection-child-process conn) child)
          (setf (parenting-connection-server conn) server)
          (setf (parenting-connection-socket-directory conn) directory)
          (when init
            (parenting-eval conn init timeout))
          conn)
      ;; On failure, tear down whatever came up.
      (unless (and conn (parenting-connection-child-process conn))
        (when conn
          (parenting-shutdown conn))
        (when (process-live-p child)
          (delete-process child))
        (when (process-live-p server)
          (delete-process server))
        (when (and directory (file-directory-p directory))
          (delete-directory directory t))))))

;;;###autoload
(defmacro parenting-with-child (spec &rest body)
  "Run BODY with a freshly spawned child Emacs, then shut it down.
SPEC is (VAR SPAWN-ARGS...): VAR is bound to the connection and the
SPAWN-ARGS keywords go to `parenting-spawn'.  The child is shut
down when BODY exits, normally or not.

This is the test-fixture shape: each use gets a hermetic,
disposable, real Emacs, so tests cannot leak state into each other
or into the test runner, and code under test may even crash its
Emacs without killing the suite.  Pass :emacs to run the same body
against another Emacs build, and :host to run it on another machine
\(the child then spawns through `parenting-spawn-remote', which
takes the remaining keywords)."
  (declare (indent 1) (debug ((symbolp &rest form) body)))
  (let* ((var (car spec))
         (keys (cdr spec))
         (host (plist-get keys :host))
         (spawn (if host
                    `(parenting-spawn-remote
                      ,host
                      ,@(cl-loop for (key value) on keys by #'cddr
                                 unless (eq key :host)
                                 append (list key value)))
                  `(parenting-spawn ,@keys))))
    `(let ((,var ,spawn))
       (unwind-protect
           (progn ,@body)
         (parenting-shutdown ,var)))))

;;; Evaluating in the child

(defun parenting-eval (conn form &optional timeout)
  "Evaluate FORM in the child Emacs on CONN and return its value.
Errors in the child are re-signaled here as `parenting-remote-error'
with the child's error symbol and data.  Values without a readable
printed form arrive as descriptive strings.  TIMEOUT overrides
`parenting-default-timeout'."
  (parenting--response-value
   (parenting--roundtrip conn (list :type 'eval :form form) timeout)))

(defun parenting-eval-async (conn form callback &optional errback)
  "Evaluate FORM in the child on CONN, then call CALLBACK with the value.
If the child signals, call ERRBACK (when non-nil) with the error
symbol and error data instead."
  (parenting--send-request
   conn (list :type 'eval :form form)
   (lambda (response)
     (pcase (plist-get response :type)
       ('result (funcall callback (plist-get response :value)))
       ('error (when errback
                 (funcall errback
                          (plist-get response :error-symbol)
                          (plist-get response :error-data)))))))
  nil)

;;; Asynchronous tasks in the child

(defcustom parenting-task-history-size 64
  "How many recent task events to retain per connection.
The live task registry is a hash table and never drops entries;
this bounded ring only feeds `parenting-task-events', a debugging
aid, so old events fall off the end."
  :type 'natnum
  :group 'parenting)

(defun parenting--task-record (conn task-id event)
  "Note that EVENT happened to TASK-ID on CONN, for debugging."
  (let ((history (or (parenting-connection-task-history conn)
                     (setf (parenting-connection-task-history conn)
                           (make-ring parenting-task-history-size)))))
    (ring-insert history (list :task-id task-id
                               :event event
                               :time (float-time)))))

(defun parenting-task-events (conn)
  "Return recent task events on CONN, most recent first.
Each event is a plist with :task-id, :event (one of `started',
`finished', `failed', or `cancelled'), and :time.  The history is a
bounded ring, so only the last `parenting-task-history-size' events
survive."
  (let ((history (parenting-connection-task-history conn)))
    (and history (ring-elements history))))

(defcustom parenting-task-results-size 256
  "Capacity of the per-connection ring of unclaimed polled results.
Also the admission limit: starting a polled task signals
`parenting-backpressure' once outstanding polled tasks plus
unclaimed results reach this, so submitters queue instead of the
ring ever having to evict a result."
  :type 'natnum
  :group 'parenting)

(defun parenting--task-results-ring (conn)
  "Return CONN's ring of unclaimed polled task results."
  (or (parenting-connection-task-results conn)
      (setf (parenting-connection-task-results conn)
            (make-ring parenting-task-results-size))))

(defun parenting--store-task-result (conn result)
  "Retain RESULT on CONN until a poller claims it.
Should the ring somehow be full despite admission control, the
oldest result is evicted and the eviction shows up in
`parenting-task-events'."
  (let ((results (parenting--task-results-ring conn)))
    (when (= (ring-length results) (ring-size results))
      (parenting--task-record
       conn
       (plist-get (ring-ref results (1- (ring-length results))) :task-id)
       'evicted))
    (ring-insert results result)))

(defun parenting--settle-task-error (conn id entry symbol data)
  "Deliver error SYMBOL with DATA for task ID's ENTRY on CONN.
Polled tasks (no callback) have the error stored for polling;
otherwise it goes to the errback, when there is one."
  (cond
   ((cdr entry)
    (funcall (cdr entry) symbol data))
   ((null (car entry))
    (parenting--store-task-result
     conn (list :task-id id :outcome 'error
                :error-symbol symbol :error-data data)))))

(defun parenting--polled-outstanding (conn)
  "Count CONN's still-running tasks that will be polled for."
  (let ((count 0))
    (maphash (lambda (_id entry)
               (unless (car entry)
                 (setq count (1+ count))))
             (parenting-connection-tasks conn))
    count))

(defun parenting-task-load (conn)
  "Return polled-task pressure on CONN, for submitters to consult.
The value is a plist of :outstanding (running polled tasks),
:unclaimed (settled results nobody polled yet), and :capacity;
`parenting-start-task' signals `parenting-backpressure' when the
first two sum to the third."
  (let ((results (parenting-connection-task-results conn)))
    (list :outstanding (parenting--polled-outstanding conn)
          :unclaimed (if results (ring-length results) 0)
          :capacity parenting-task-results-size)))

(defun parenting-start-task (conn form &optional callback errback)
  "Start FORM as an asynchronous task in the child on CONN.
Return the task id immediately, without blocking either Emacs.  The
child evaluates FORM with `parenting-current-task' bound to a task
handle; FORM must capture that handle lexically and arrange for
`parenting-task-finish' or `parenting-task-fail' to be called on it
eventually, typically from a process sentinel or timer.  If FORM
itself signals during this initial evaluation, the task fails.

CALLBACK receives the finished value; ERRBACK, when non-nil,
receives an error symbol and its data on failure, cancellation, or
disconnect.  With CALLBACK nil the task is polled instead: its
settled result is retained until claimed with `parenting-poll-task'
or `parenting-drain-task-results'.  In that case this signals
`parenting-backpressure' when CONN already carries
`parenting-task-results-size' polled tasks and unclaimed results
combined — submitters should queue and retry after polling."
  (when (null callback)
    (let ((load (parenting-task-load conn)))
      (when (>= (+ (plist-get load :outstanding)
                   (plist-get load :unclaimed))
                (plist-get load :capacity))
        (signal 'parenting-backpressure (list conn load)))))
  (let* ((tasks (parenting-connection-tasks conn))
         (id nil))
    (setq id (parenting--send-request
              conn (list :type 'task :form form)
              (lambda (response)
                ;; The ack.  An error here means the request itself
                ;; was rejected, so the task will never complete.
                (when (eq (plist-get response :type) 'error)
                  (let ((entry (gethash id tasks)))
                    (when entry
                      (remhash id tasks)
                      (parenting--task-record conn id 'failed)
                      (parenting--settle-task-error
                       conn id entry
                       (plist-get response :error-symbol)
                       (plist-get response :error-data))))))))
    (puthash id (cons callback errback) tasks)
    (parenting--task-record conn id 'started)
    id))

(defun parenting--handle-task-complete (conn message)
  "Settle the task whose completion MESSAGE reports on CONN."
  (let* ((tasks (parenting-connection-tasks conn))
         (id (plist-get message :task-id))
         (entry (gethash id tasks)))
    (when entry
      (remhash id tasks)
      (pcase (plist-get message :outcome)
        ('result
         (parenting--task-record conn id 'finished)
         (if (car entry)
             (funcall (car entry) (plist-get message :value))
           (parenting--store-task-result
            conn (list :task-id id :outcome 'result
                       :value (plist-get message :value)))))
        ('error
         (parenting--task-record conn id 'failed)
         (parenting--settle-task-error
          conn id entry
          (plist-get message :error-symbol)
          (plist-get message :error-data)))))))

(defun parenting-poll-task (conn task-id)
  "Return the state of TASK-ID on CONN, claiming a settled result.
Still-running tasks yield (:task-id ID :outcome running), without
claiming anything.  Settled results — (:task-id ID :outcome result
:value V) or (:task-id ID :outcome error :error-symbol S
:error-data D) — are removed as they are returned, so a second poll
yields nil.  Nil also means the id is unknown: never started,
claimed earlier, or evicted."
  (if (gethash task-id (parenting-connection-tasks conn))
      (list :task-id task-id :outcome 'running)
    (let ((results (parenting-connection-task-results conn))
          (found nil))
      (when results
        (dotimes (i (ring-length results))
          (when (and (null found)
                     (eql task-id
                          (plist-get (ring-ref results i) :task-id)))
            (setq found (ring-remove results i)))))
      found)))

(defun parenting-drain-task-results (conn)
  "Claim and return all unclaimed settled task results on CONN.
Oldest first.  See `parenting-poll-task' for the result shape."
  (let ((results (parenting-connection-task-results conn))
        (claimed nil))
    (when results
      (while (not (ring-empty-p results))
        (push (ring-remove results) claimed)))
    (nreverse claimed)))

(setf (alist-get '(parent . task-complete)
                 parenting--notification-handlers
                 nil nil #'equal)
      #'parenting--handle-task-complete)

(defun parenting-cancel-task (conn task-id)
  "Cancel TASK-ID on CONN; return non-nil if it was still live.
The child runs the cancel function the task registered with
`parenting-task-on-cancel', if any, and a completion racing with
the cancellation is ignored on both sides.  The task's errback,
when it has one, is called with `parenting-cancelled'."
  (let* ((tasks (parenting-connection-tasks conn))
         (entry (gethash task-id tasks)))
    (when entry
      (remhash task-id tasks)
      (parenting--task-record conn task-id 'cancelled)
      (ignore-errors
        (parenting--send conn (list :type 'task-cancel
                                    :task-id task-id)))
      (parenting--settle-task-error conn task-id entry
                                    'parenting-cancelled nil)
      t)))

(defun parenting-run-task (conn form &optional timeout)
  "Start FORM as a task in the child on CONN and await its value.
Like `parenting-start-task' but synchronous: blocks this Emacs (the
child stays responsive) until the task settles.  On failure signals
`parenting-remote-error'.  After TIMEOUT seconds (default
`parenting-default-timeout') the task is cancelled in the child and
`parenting-timeout' is signaled."
  (let* ((outcome nil)
         (process (parenting-connection-process conn))
         (deadline (+ (float-time) (or timeout parenting-default-timeout)))
         (task-id (parenting-start-task
                   conn form
                   (lambda (value) (setq outcome (list 'result value)))
                   (lambda (symbol data)
                     (setq outcome (list 'error symbol data))))))
    (while (and (null outcome) (process-live-p process))
      (when (> (float-time) deadline)
        (parenting-cancel-task conn task-id)
        (signal 'parenting-timeout (list form)))
      (accept-process-output process 0.05))
    (unless outcome
      (signal 'parenting-closed (list conn)))
    (pcase outcome
      (`(result ,value) value)
      (`(error ,symbol ,data)
       (signal 'parenting-remote-error (list symbol data))))))

(defun parenting--fail-tasks-on-close (conn)
  "Fail every task still outstanding on CONN, which just closed."
  (when (eq (parenting-connection-role conn) 'parent)
    (let ((tasks (parenting-connection-tasks conn))
          (entries nil))
      (maphash (lambda (id entry) (push (cons id entry) entries)) tasks)
      (clrhash tasks)
      (dolist (entry entries)
        (parenting--task-record conn (car entry) 'failed)
        (parenting--settle-task-error conn (car entry) (cdr entry)
                                      'parenting-closed nil)))))

(add-hook 'parenting-connection-close-functions
          #'parenting--fail-tasks-on-close)

(defun parenting-read-connection ()
  "Prompt for one of the live connections in `parenting-connections'."
  (let ((live (cl-remove-if-not #'parenting-connection-live-p
                                parenting-connections)))
    (unless live
      (user-error "No live parenting connections"))
    (if (null (cdr live))
        (car live)
      (let* ((names (mapcar (lambda (conn)
                              (cons (process-name
                                     (parenting-connection-process conn))
                                    conn))
                            live))
             (choice (completing-read "Child: " names nil t)))
        (cdr (assoc choice names))))))

;;;###autoload
(defun parenting-eval-expression (conn form)
  "Interactively evaluate FORM in the child on CONN and echo the value."
  (interactive
   (list (parenting-read-connection)
         (read-from-minibuffer "Eval in child: " nil read-expression-map t
                               'read-expression-history)))
  (let ((value (parenting-eval conn form)))
    (when (called-interactively-p 'interactive)
      (message "%S" value))
    value))

(provide 'parenting-parent)
;;; parenting-parent.el ends here
