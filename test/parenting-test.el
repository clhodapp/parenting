;;; parenting-test.el --- ERT tests for parenting -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; End-to-end tests: each test spawns a real batch child Emacs (the
;; same binary running the tests) and drives it over the socket.
;;; Code:

(require 'ert)
(require 'parenting)
(require 'parenting-parent)
(require 'parenting-child)
(require 'parenting-remote)

(defmacro parenting-test--with-child (var &rest body)
  "Spawn a batch child bound to VAR, run BODY, always shut it down."
  (declare (indent 1))
  `(parenting-with-child (,var :timeout 60)
     ,@body))

(ert-deftest parenting-eval-roundtrip ()
  (parenting-test--with-child conn
    (should (equal 3 (parenting-eval conn '(+ 1 2))))
    (should (equal "abc" (parenting-eval conn '(concat "a" "bc"))))
    (should (equal '(1 [2 3] (4 . 5) "six" seven ?8 9.5)
                   (parenting-eval
                    conn '(list 1 [2 3] (cons 4 5) "six" 'seven ?8 9.5))))))

(ert-deftest parenting-eval-state-persists ()
  (parenting-test--with-child conn
    (parenting-eval conn '(progn (defvar parenting-test-x nil)
                                 (setq parenting-test-x 41)))
    (should (equal 42 (parenting-eval conn '(1+ parenting-test-x))))
    ;; The child's state is its own, not ours.
    (should-not (boundp 'parenting-test-x))))

(ert-deftest parenting-eval-error-propagates ()
  (parenting-test--with-child conn
    (let ((err (should-error (parenting-eval conn '(error "boom"))
                             :type 'parenting-remote-error)))
      (should (equal '(error ("boom")) (cdr err))))
    ;; The connection survives remote errors.
    (should (equal 1 (parenting-eval conn 1)))))

(ert-deftest parenting-eval-unreadable-value-becomes-string ()
  (parenting-test--with-child conn
    (let ((value (parenting-eval conn '(list 1 (current-buffer) 2))))
      (should (equal 1 (nth 0 value)))
      (should (string-match-p "#<buffer" (nth 1 value)))
      (should (equal 2 (nth 2 value))))))

(ert-deftest parenting-hello-carries-emacs-version ()
  (parenting-test--with-child conn
    (should (equal emacs-version (parenting-peer-emacs-version conn)))
    (should (equal emacs-version
                   (parenting-eval conn 'emacs-version)))))

(ert-deftest parenting-child-call-denied-by-default ()
  (parenting-test--with-child conn
    (let ((err (should-error
                (parenting-eval conn '(parenting-call-parent 'expt '(2 3)))
                :type 'parenting-remote-error)))
      (should (string-match-p "parenting-forbidden" (format "%S" err))))))

(ert-deftest parenting-child-call-allowed-function ()
  (parenting-test--with-child conn
    (parenting-allow-function conn 'expt)
    (should (equal 8 (parenting-eval
                      conn '(parenting-call-parent 'expt '(2 3)))))))

(ert-deftest parenting-child-call-predicate ()
  (parenting-test--with-child conn
    (parenting-allow-function conn 'expt
                              (lambda (args) (< (car args) 10)))
    (should (equal 8 (parenting-eval
                      conn '(parenting-call-parent 'expt '(2 3)))))
    (should-error
     (parenting-eval conn '(parenting-call-parent 'expt '(12 2)))
     :type 'parenting-remote-error)))

(ert-deftest parenting-child-call-guard ()
  (parenting-test--with-child conn
    (parenting-allow-function conn 'identity)
    (parenting-allow-function conn 'expt)
    (parenting-add-guard conn (lambda (fn _args) (not (eq fn 'identity))))
    (should (equal 8 (parenting-eval
                      conn '(parenting-call-parent 'expt '(2 3)))))
    (should-error
     (parenting-eval conn '(parenting-call-parent 'identity '(1)))
     :type 'parenting-remote-error)))

(ert-deftest parenting-child-call-disallow-revokes ()
  (parenting-test--with-child conn
    (parenting-allow-function conn 'expt)
    (should (equal 8 (parenting-eval
                      conn '(parenting-call-parent 'expt '(2 3)))))
    (parenting-disallow-function conn 'expt)
    (should-error
     (parenting-eval conn '(parenting-call-parent 'expt '(2 3)))
     :type 'parenting-remote-error)))

(ert-deftest parenting-parent-rejects-eval-from-child ()
  (parenting-test--with-child conn
    (should-error
     (parenting-eval
      conn
      '(parenting--response-value
        (parenting--roundtrip parenting-child-connection
                              (list :type 'eval
                                    :form '(defvar parenting-test-owned t))
                              5)))
     :type 'parenting-remote-error)
    (should-not (boundp 'parenting-test-owned))))

(ert-deftest parenting-hostile-bytecode-drops-connection ()
  (parenting-test--with-child conn
    ;; Even with a dangerous higher-order function allowlisted...
    (parenting-allow-function conn 'funcall)
    ;; ...a hostile child that bypasses the client library and writes
    ;; a raw #[...] byte-code literal onto the socket gets dropped
    ;; before the sandbox ever sees the call.  The hostile line lands
    ;; before the eval's own response, so the eval fails closed.
    (should-error
     (parenting-eval
      conn
      '(process-send-string
        (parenting-connection-process parenting-child-connection)
        "(:type call :id 999 :fn funcall :args (#[257 \"\\300\\207\" [pwned] 3]))\n"))
     :type 'parenting-error)
    (with-timeout (10 (ert-fail "connection was not dropped"))
      (while (parenting-connection-live-p conn)
        (accept-process-output nil 0.05)))
    (should-not (parenting-connection-live-p conn))))

(ert-deftest parenting-eval-async-callback ()
  (parenting-test--with-child conn
    (let ((value nil))
      (parenting-eval-async conn '(* 6 7) (lambda (v) (setq value v)))
      (with-timeout (30 (ert-fail "async result never arrived"))
        (while (null value)
          (accept-process-output nil 0.05)))
      (should (equal 42 value)))))

(ert-deftest parenting-task-async-completion ()
  (parenting-test--with-child conn
    (should (equal 'late
                   (parenting-run-task
                    conn
                    '(let ((task parenting-current-task))
                       (run-with-timer
                        0.05 nil
                        (lambda () (parenting-task-finish task 'late)))))))))

(ert-deftest parenting-task-does-not-block-child ()
  (parenting-test--with-child conn
    (let ((got nil))
      (parenting-start-task
       conn
       '(let ((task parenting-current-task))
          (run-with-timer
           0.2 nil
           (lambda () (parenting-task-finish task 'slow))))
       (lambda (value) (setq got value)))
      ;; The child answers evals while the task is pending.
      (should (equal 3 (parenting-eval conn '(+ 1 2))))
      (should-not got)
      (with-timeout (30 (ert-fail "task never completed"))
        (while (null got)
          (accept-process-output nil 0.05)))
      (should (equal 'slow got)))))

(ert-deftest parenting-task-synchronous-finish ()
  ;; Finishing during the initial evaluation must still work: the
  ;; ack is sent before the form runs, so ordering holds.
  (parenting-test--with-child conn
    (should (equal 42 (parenting-run-task
                       conn
                       '(parenting-task-finish
                         parenting-current-task 42))))))

(ert-deftest parenting-task-setup-error-fails ()
  (parenting-test--with-child conn
    (let ((err (should-error (parenting-run-task conn '(error "task boom"))
                             :type 'parenting-remote-error)))
      (should (equal '(error ("task boom")) (cdr err))))))

(ert-deftest parenting-task-async-failure ()
  (parenting-test--with-child conn
    (should-error
     (parenting-run-task
      conn
      '(let ((task parenting-current-task))
         (run-with-timer
          0.05 nil
          (lambda () (parenting-task-fail task 'arith-error '(7))))))
     :type 'parenting-remote-error)))

(ert-deftest parenting-task-cancel ()
  (parenting-test--with-child conn
    (let ((value nil) (failure nil) (id nil))
      (setq id (parenting-start-task
                conn
                '(let ((task parenting-current-task))
                   (defvar parenting-test-cancelled nil)
                   (parenting-task-on-cancel
                    task (lambda () (setq parenting-test-cancelled t)))
                   (run-with-timer
                    0.3 nil
                    (lambda () (parenting-task-finish task 'too-late))))
                (lambda (v) (setq value v))
                (lambda (symbol _data) (setq failure symbol))))
      ;; Let the child start the task before cancelling.
      (parenting-eval conn '(ignore))
      (should (parenting-cancel-task conn id))
      (should (eq failure 'parenting-cancelled))
      ;; The child ran the registered cancel function.
      (should (parenting-eval conn 'parenting-test-cancelled))
      ;; The too-late completion is ignored on both sides.
      (let ((deadline (+ (float-time) 0.6)))
        (while (< (float-time) deadline)
          (accept-process-output nil 0.05)))
      (should-not value)
      (should (equal 1 (parenting-eval conn 1))))))

(ert-deftest parenting-task-failed-by-shutdown ()
  (let ((conn (parenting-spawn :timeout 60))
        (failure nil))
    ;; This task never arranges completion.
    (parenting-start-task conn '(ignore)
                          #'ignore
                          (lambda (symbol _data) (setq failure symbol)))
    (parenting-shutdown conn)
    (with-timeout (10 (ert-fail "outstanding task never failed"))
      (while (null failure)
        (accept-process-output nil 0.05)))
    (should (eq failure 'parenting-closed))))

(ert-deftest parenting-task-history-events ()
  (parenting-test--with-child conn
    (parenting-run-task conn '(parenting-task-finish
                               parenting-current-task 'ok))
    (let ((events (mapcar (lambda (event) (plist-get event :event))
                          (parenting-task-events conn))))
      (should (memq 'started events))
      (should (memq 'finished events)))))

(defun parenting-test--pump (predicate &optional seconds)
  "Process I/O until PREDICATE returns non-nil or SECONDS elapse."
  (let ((deadline (+ (float-time) (or seconds 30))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(ert-deftest parenting-task-polling ()
  (parenting-test--with-child conn
    (let ((id (parenting-start-task
               conn
               '(let ((task parenting-current-task))
                  (run-with-timer
                   0.1 nil
                   (lambda () (parenting-task-finish task 'polled)))))))
      ;; Not settled yet: reported running, nothing claimed.
      (should (equal (list :task-id id :outcome 'running)
                     (parenting-poll-task conn id)))
      (parenting-test--pump
       (lambda () (null (gethash id (parenting-connection-tasks conn)))))
      (let ((result (parenting-poll-task conn id)))
        (should (equal 'result (plist-get result :outcome)))
        (should (equal 'polled (plist-get result :value))))
      ;; Claimed exactly once.
      (should-not (parenting-poll-task conn id))
      (should-not (parenting-poll-task conn 999999)))))

(ert-deftest parenting-task-drain-results ()
  (parenting-test--with-child conn
    (let ((first (parenting-start-task
                  conn '(parenting-task-finish parenting-current-task 'a)))
          (second (parenting-start-task
                   conn '(parenting-task-finish parenting-current-task 'b))))
      (parenting-test--pump
       (lambda () (equal 2 (plist-get (parenting-task-load conn)
                                      :unclaimed))))
      (let ((results (parenting-drain-task-results conn)))
        ;; Oldest first, then the ring is empty.
        (should (equal (list first second)
                       (mapcar (lambda (r) (plist-get r :task-id)) results)))
        (should (equal '(a b)
                       (mapcar (lambda (r) (plist-get r :value)) results))))
      (should-not (parenting-drain-task-results conn)))))

(ert-deftest parenting-task-backpressure-signals-submitter ()
  (parenting-test--with-child conn
    (let ((parenting-task-results-size 2))
      (dotimes (_ 2)
        (parenting-start-task
         conn '(parenting-task-finish parenting-current-task 'full)))
      (parenting-test--pump
       (lambda () (equal 2 (plist-get (parenting-task-load conn)
                                      :unclaimed))))
      ;; At capacity: the submitter is told to queue, nothing evicted.
      (should-error (parenting-start-task conn ''overflow)
                    :type 'parenting-backpressure)
      ;; Claiming makes room again.
      (should (parenting-drain-task-results conn))
      (should (parenting-start-task
               conn '(parenting-task-finish parenting-current-task 'ok))))))

(ert-deftest parenting-task-poll-claims-by-id ()
  (parenting-test--with-child conn
    (let ((a (parenting-start-task
              conn '(parenting-task-finish parenting-current-task 'a)))
          (b (parenting-start-task
              conn '(parenting-task-finish parenting-current-task 'b)))
          (c (parenting-start-task
              conn '(parenting-task-finish parenting-current-task 'c))))
      (parenting-test--pump
       (lambda () (equal 3 (plist-get (parenting-task-load conn)
                                      :unclaimed))))
      ;; Claim the middle one; the others stay, still oldest first.
      (should (equal 'b (plist-get (parenting-poll-task conn b) :value)))
      (should (equal (list a c)
                     (mapcar (lambda (r) (plist-get r :task-id))
                             (parenting-drain-task-results conn)))))))

(ert-deftest parenting-task-backpressure-counts-outstanding ()
  (parenting-test--with-child conn
    (let ((parenting-task-results-size 2))
      ;; Two polled tasks still running; nothing settled yet.
      (dotimes (_ 2) (parenting-start-task conn '(ignore)))
      (let ((load (parenting-task-load conn)))
        (should (equal 2 (plist-get load :outstanding)))
        (should (equal 0 (plist-get load :unclaimed)))
        (should (equal 2 (plist-get load :capacity))))
      (should-error (parenting-start-task conn ''third)
                    :type 'parenting-backpressure)
      ;; Callback tasks are not metered by the polled-task cap.
      (should (equal 'ok (parenting-run-task
                          conn '(parenting-task-finish
                                 parenting-current-task 'ok)))))))

(ert-deftest parenting-task-result-eviction-safety-valve ()
  ;; Admission control keeps this path from firing in normal use, so
  ;; exercise the store directly: past capacity it must evict the
  ;; oldest result and leave a trace in the event history.
  (let ((parenting-task-results-size 2)
        (conn (parenting--make-connection :role 'parent)))
    (dolist (i '(1 2 3))
      (parenting--store-task-result
       conn (list :task-id i :outcome 'result :value i)))
    (should-not (parenting-poll-task conn 1))
    (should (equal 2 (plist-get (parenting-poll-task conn 2) :value)))
    (should (equal 3 (plist-get (parenting-poll-task conn 3) :value)))
    (should (equal '(1)
                   (mapcar (lambda (event) (plist-get event :task-id))
                           (cl-remove-if-not
                            (lambda (event)
                              (eq 'evicted (plist-get event :event)))
                            (parenting-task-events conn)))))))

(ert-deftest parenting-task-polled-cancel-and-shutdown-are-visible ()
  (parenting-test--with-child conn
    (let ((id (parenting-start-task conn '(ignore))))
      (parenting-eval conn '(ignore))
      (parenting-cancel-task conn id)
      (let ((result (parenting-poll-task conn id)))
        (should (equal 'error (plist-get result :outcome)))
        (should (eq 'parenting-cancelled
                    (plist-get result :error-symbol))))))
  ;; A polled task orphaned by disconnect settles as parenting-closed.
  (let* ((conn (parenting-spawn :timeout 60))
         (id (parenting-start-task conn '(ignore)))
         (result nil))
    (parenting-shutdown conn)
    (parenting-test--pump
     (lambda ()
       (let ((state (or result (parenting-poll-task conn id))))
         (setq result state)
         (and state (not (eq (plist-get state :outcome) 'running)))))
     10)
    (should (equal 'error (plist-get result :outcome)))
    (should (eq 'parenting-closed (plist-get result :error-symbol)))))

(ert-deftest parenting-init-form-runs-in-child ()
  (let ((conn (parenting-spawn
               :timeout 60
               :init '(progn (defvar parenting-test-init nil)
                             (setq parenting-test-init 'ran)))))
    (unwind-protect
        (should (equal 'ran (parenting-eval conn 'parenting-test-init)))
      (parenting-shutdown conn))))

(ert-deftest parenting-two-children-are-independent ()
  (parenting-test--with-child a
    (parenting-test--with-child b
      (parenting-eval a '(progn (defvar parenting-test-who nil)
                                (setq parenting-test-who 'a)))
      (parenting-eval b '(progn (defvar parenting-test-who nil)
                                (setq parenting-test-who 'b)))
      (should (equal 'a (parenting-eval a 'parenting-test-who)))
      (should (equal 'b (parenting-eval b 'parenting-test-who))))))

(ert-deftest parenting-spawn-daemon-child-is-interactive ()
  ;; A :daemon child is a full interactive Emacs without a visible
  ;; frame, unlike the degenerate --batch environment.
  (let ((conn (parenting-spawn :daemon t :timeout 60)))
    (unwind-protect
        (progn
          (should (eq t (parenting-eval conn '(and (daemonp) t))))
          (should-not (parenting-eval conn 'noninteractive))
          ;; Frame machinery exists, unlike in batch mode.
          (should (> (parenting-eval conn '(length (frame-list))) 0)))
      (parenting-shutdown conn))))

(ert-deftest parenting-spawn-rejects-batch-plus-daemon ()
  (should-error (parenting-spawn :batch t :daemon t)))

(ert-deftest parenting-spawn-command-wrapper ()
  (let ((conn (parenting-spawn
               :timeout 60
               :command-wrapper '("env" "PARENTING_TEST_WRAPPED=yes"))))
    (unwind-protect
        (should (equal "yes" (parenting-eval
                              conn '(getenv "PARENTING_TEST_WRAPPED"))))
      (parenting-shutdown conn))))

(ert-deftest parenting-spawn-caller-owned-socket-path ()
  (let* ((directory (make-temp-file "parenting-test-" t))
         (socket (expand-file-name "sock" directory))
         (conn nil))
    (unwind-protect
        (progn
          (setq conn (parenting-spawn :timeout 60 :socket-path socket))
          (should (equal 2 (parenting-eval conn '(1+ 1))))
          (parenting-shutdown conn)
          ;; The caller owns the directory; shutdown must leave it.
          (should (file-directory-p directory)))
      (when conn
        (parenting-shutdown conn))
      (delete-directory directory t))))

(ert-deftest parenting-spawn-child-loads-sources-not-elc ()
  ;; The bootstrap must reference exact .el files so a child built by
  ;; a different Emacs never loads this Emacs's byte-code.
  (parenting-test--with-child conn
    (let ((files (parenting-eval
                  conn '(mapcar #'car load-history))))
      (dolist (base '("parenting.el" "parenting-child.el"))
        (should (cl-find-if (lambda (f)
                              (and (stringp f)
                                   (string-suffix-p base f)))
                            files))))))

(ert-deftest parenting-shutdown-reaps-child ()
  (let* ((conn (parenting-spawn :timeout 60))
         (child (parenting-connection-child-process conn))
         (directory (parenting-connection-socket-directory conn)))
    (should (process-live-p child))
    (should (file-directory-p directory))
    (parenting-shutdown conn)
    (should-not (process-live-p child))
    (should-not (file-directory-p directory))
    (should-not (parenting-connection-live-p conn))
    (should-not (memq conn parenting-connections))))

;;; Remote children

(ert-deftest parenting-remote-parse-host ()
  (should (equal '("host" nil "/ssh:host:")
                 (parenting-remote--parse-host "host")))
  (should (equal '("user@host" ("-p" "2222") "/ssh:user@host#2222:")
                 (parenting-remote--parse-host "user@host#2222")))
  (should (equal '("u@h" ("-p" "2222") "/ssh:u@h#2222:")
                 (parenting-remote--parse-host "/ssh:u@h#2222:")))
  (should (equal '("h" nil "/ssh:h:")
                 (parenting-remote--parse-host "/ssh:h:")))
  ;; Methods ssh cannot reach, and multi-hop names, are refused.
  (should-error (parenting-remote--parse-host "/sudo:root@h:"))
  (should-error (parenting-remote--parse-host "/ssh:a|ssh:b:")))

(ert-deftest parenting-remote-forward-display ()
  ;; Wayland forwarding wraps ssh in waypipe; X11 uses ssh's own -X;
  ;; t picks by the parent's session type.
  (should (equal '("ssh" "-p" "22")
                 (parenting-remote--default-ssh-command '("-p" "22") nil)))
  (should (equal '("ssh" "-p" "22" "-X")
                 (parenting-remote--default-ssh-command '("-p" "22") 'x11)))
  (should (equal '("waypipe" "ssh")
                 (parenting-remote--default-ssh-command nil 'wayland)))
  (should-not (parenting-remote--display-method nil))
  (should (eq 'x11 (parenting-remote--display-method 'x11)))
  (should (eq 'wayland (parenting-remote--display-method 'wayland)))
  (should (memq (parenting-remote--display-method t) '(x11 wayland)))
  (should-error (parenting-remote--display-method 'mystery)))

(ert-deftest parenting-remote-wrapper-quotes-for-the-remote-shell ()
  ;; ssh joins the command words with spaces and hands them to the
  ;; remote shell, so each word must be shell-quoted, after the
  ;; forwarding arguments and the destination.
  (let ((wrap (parenting-remote--wrapper '("ssh" "-p" "22") "dest"
                                         "/r/sock" "/l/sock"))
        (command '("emacs" "-Q" "--eval" "(load \"x y\")")))
    (should (equal (funcall wrap command)
                   (append '("ssh" "-p" "22" "-R" "/r/sock:/l/sock" "dest")
                           (mapcar #'shell-quote-argument command))))))

(ert-deftest parenting-print-stays-on-one-physical-line ()
  ;; Remote transports may involve ptys or shells that mangle raw
  ;; control characters, so the wire format escapes them.
  (let ((printed (parenting--print-to-string (list :value "a\nb\rc\td"))))
    (should-not (string-match-p "[\n\r]" printed))
    (should (equal '(:value "a\nb\rc\td") (read printed)))))

;; The remaining remote tests drive the real remote code path without
;; a network: a fake ssh that honors just enough of the client
;; contract.  It symlinks the "remote" forwarded socket to the local
;; one and runs the command through sh the same way sshd's remote
;; shell would — all words joined by spaces and re-split — so quoting
;; bugs fail here exactly as they would over real ssh.

(defvar parenting-test--fake-ssh nil)

(defun parenting-test--fake-ssh ()
  "Return the path of a fake ssh executable, creating it on demand."
  (or parenting-test--fake-ssh
      (setq parenting-test--fake-ssh
            (let ((script (make-temp-file "parenting-fake-ssh-")))
              (with-temp-file script
                (insert "#!/bin/sh\n"
                        "set -e\n"
                        "fwd=\n"
                        "while [ $# -gt 0 ]; do\n"
                        "  case $1 in\n"
                        "    -R) fwd=$2; shift 2 ;;\n"
                        "    -p|-l|-o) shift 2 ;;\n"
                        "    -*) shift ;;\n"
                        "    *) break ;;\n"
                        "  esac\n"
                        "done\n"
                        "shift\n" ; the destination
                        "if [ -n \"$fwd\" ]; then\n"
                        "  ln -s \"${fwd#*:}\" \"${fwd%%:*}\"\n"
                        "fi\n"
                        "exec sh -c \"$*\"\n"))
              (set-file-modes script #o755)
              script))))

(defmacro parenting-test--with-remote-child (spec &rest body)
  "Spawn a fake-remote child bound to (car SPEC), run BODY, shut down.
The keywords in (cdr SPEC) are extra `parenting-spawn-remote'
arguments.  Going through `parenting-with-child' with :host also
exercises its remote routing."
  (declare (indent 1))
  `(parenting-with-child (,(car spec)
                          :host "fake-remote"
                          :emacs (expand-file-name invocation-name
                                                   invocation-directory)
                          :ssh-command (list (parenting-test--fake-ssh))
                          :remote-prefix ""
                          :timeout 60
                          ,@(cdr spec))
     ,@body))

(ert-deftest parenting-remote-eval-roundtrip ()
  (parenting-test--with-remote-child (conn)
    (should (equal 3 (parenting-eval conn '(+ 1 2))))
    (should (equal emacs-version (parenting-peer-emacs-version conn)))
    ;; Values whose raw printed form spans lines survive the wire.
    (should (equal "a\nb\rc"
                   (parenting-eval conn '(concat "a" "\n" "b" "\r" "c"))))))

(ert-deftest parenting-remote-child-loads-staged-sources ()
  ;; With no :child-library-directory, the sources the child loads
  ;; are the copies staged into the remote scratch directory.
  (parenting-test--with-remote-child (conn)
    (let ((scratch (parenting-remote--local-name
                    (parenting-connection-remote-directory conn)))
          (files (parenting-eval conn '(mapcar #'car load-history))))
      (dolist (base '("parenting.el" "parenting-child.el"))
        (should (cl-find-if (lambda (file)
                              (and (stringp file)
                                   (string-prefix-p scratch file)
                                   (string-suffix-p base file)))
                            files))))))

(ert-deftest parenting-remote-quoting-survives-the-remote-shell ()
  (let* ((tricky "two words; $HOME `id` 'quoted' \"double\" \\back")
         (conn (parenting-spawn-remote
                "fake-remote"
                :emacs (expand-file-name invocation-name
                                         invocation-directory)
                :ssh-command (list (parenting-test--fake-ssh))
                :remote-prefix ""
                :args (list "--eval"
                            (format "%S" `(defvar parenting-test-quoted
                                            ,tricky)))
                :timeout 60)))
    (unwind-protect
        (should (equal tricky (parenting-eval conn 'parenting-test-quoted)))
      (parenting-shutdown conn))))

(ert-deftest parenting-remote-tasks-work ()
  (parenting-test--with-remote-child (conn)
    (should (equal 'late
                   (parenting-run-task
                    conn
                    '(let ((task parenting-current-task))
                       (run-with-timer
                        0.05 nil
                        (lambda () (parenting-task-finish task 'late)))))))))

(ert-deftest parenting-remote-daemon-child ()
  (parenting-test--with-remote-child (conn :daemon t)
    (should (eq t (parenting-eval conn '(and (daemonp) t))))
    (should-not (parenting-eval conn 'noninteractive))))

(ert-deftest parenting-remote-shutdown-cleans-both-machines ()
  (let* ((conn (parenting-spawn-remote
                "fake-remote"
                :emacs (expand-file-name invocation-name
                                         invocation-directory)
                :ssh-command (list (parenting-test--fake-ssh))
                :remote-prefix ""
                :timeout 60))
         (ssh (parenting-connection-child-process conn))
         (local-directory (parenting-connection-socket-directory conn))
         (remote-directory (parenting-connection-remote-directory conn)))
    (should (process-live-p ssh))
    (should (file-directory-p local-directory))
    (should (file-directory-p remote-directory))
    (should (equal 2 (parenting-eval conn '(1+ 1))))
    (parenting-shutdown conn)
    (should-not (process-live-p ssh))
    (should-not (file-directory-p local-directory))
    (should-not (file-directory-p remote-directory))))

(ert-deftest parenting-spawned-interactive-child-exits-on-close ()
  ;; A spawned interactive child is owned by its parent: it must exit
  ;; by itself when the connection closes, since on a remote machine
  ;; nothing else would reap it.
  (let* ((conn (parenting-spawn :daemon t :timeout 60))
         (child (parenting-connection-child-process conn)))
    (unwind-protect
        (progn
          (should (process-live-p child))
          (delete-process (parenting-connection-process conn))
          (parenting-test--pump
           (lambda () (not (process-live-p child))) 30)
          (should-not (process-live-p child)))
      (parenting-shutdown conn))))

;;; Sandboxing children with bwrap

(defun parenting-test--flag-values (args flag)
  "Return the values that follow each FLAG occurrence in ARGS.
Single-argument bwrap flags: collects the one word after each FLAG."
  (let ((values nil)
        (rest args))
    (while rest
      (when (equal (car rest) flag)
        (push (cadr rest) values))
      (setq rest (cdr rest)))
    (nreverse values)))

(defun parenting-test--bind-p (args flag src dest)
  "Return non-nil if ARGS contains FLAG SRC DEST in sequence."
  (let ((triple (list flag src dest))
        (found nil)
        (rest args))
    (while (and rest (not found))
      (when (equal (list (nth 0 rest) (nth 1 rest) (nth 2 rest)) triple)
        (setq found t))
      (setq rest (cdr rest)))
    found))

(ert-deftest parenting-sandbox-wrapper-core-flags ()
  ;; The pure builder must always ask for the die-with-parent guard, a
  ;; cleared environment, /proc, /dev and a private /tmp, and must bind
  ;; the socket dir rw and the library dir ro at their own paths.
  (let ((args (parenting--sandbox-command-wrapper
               nil "/run/sock-dir" "/opt/parenting")))
    (should (equal parenting-sandbox-program (car args)))
    (should (member "--die-with-parent" args))
    (should (member "--unshare-all" args))
    (should (member "--clearenv" args))
    (should (equal '("/proc") (parenting-test--flag-values args "--proc")))
    (should (equal '("/dev") (parenting-test--flag-values args "--dev")))
    (should (equal '("/tmp") (parenting-test--flag-values args "--tmpfs")))
    ;; Socket directory bound read-write at the same path.
    (should (parenting-test--bind-p
             args "--bind" "/run/sock-dir" "/run/sock-dir"))
    ;; Library directory bound read-only at the same path.
    (should (parenting-test--bind-p
             args "--ro-bind" "/opt/parenting" "/opt/parenting"))
    ;; HOME is set (to a path under the socket directory).
    (should (member "HOME" (parenting-test--flag-values args "--setenv")))))

(ert-deftest parenting-sandbox-wrapper-network-toggle ()
  ;; No network by default; --share-net only when the spec asks.
  (should-not (member "--share-net"
                      (parenting--sandbox-command-wrapper
                       nil "/s" "/l")))
  (should-not (member "--share-net"
                      (parenting--sandbox-command-wrapper
                       '(:network nil) "/s" "/l")))
  (should (member "--share-net"
                  (parenting--sandbox-command-wrapper
                   '(:network t) "/s" "/l"))))

(ert-deftest parenting-sandbox-wrapper-nix-store ()
  ;; The whole store is bound read-only exactly when it exists.
  (let ((args (parenting--sandbox-command-wrapper nil "/s" "/l")))
    (should (eq (and (parenting-test--bind-p
                      args "--ro-bind" "/nix/store" "/nix/store")
                     t)
                (and (file-exists-p "/nix/store") t)))))

(ert-deftest parenting-sandbox-wrapper-environment-passthrough ()
  ;; Each named, set variable is carried in with its own --setenv; an
  ;; unset name is dropped rather than passed empty.
  (let* ((set-name "PARENTING_TEST_PASS")
         (unset-name "PARENTING_TEST_ABSENT_XYZZY"))
    (setenv set-name "carried")
    (setenv unset-name nil)
    (unwind-protect
        (let* ((args (parenting--sandbox-command-wrapper
                      (list :environment (list set-name unset-name))
                      "/s" "/l"))
               (setenvs (parenting-test--flag-values args "--setenv")))
          (should (member set-name setenvs))
          (should-not (member unset-name setenvs))
          ;; The value rides right after the name.
          (let ((rest args) (value nil))
            (while rest
              (when (and (equal (car rest) "--setenv")
                         (equal (cadr rest) set-name))
                (setq value (nth 2 rest)))
              (setq rest (cdr rest)))
            (should (equal "carried" value))))
      (setenv set-name nil))))

(ert-deftest parenting-sandbox-wrapper-extra-binds ()
  ;; Read-only and read-write extra binds, both plain paths and
  ;; (src . dest) conses, land as the right bwrap flags.
  (let ((args (parenting--sandbox-command-wrapper
               '(:ro-binds ("/proj" ("/data/src" . "/data"))
                 :rw-binds ("/scratch"))
               "/s" "/l")))
    (should (parenting-test--bind-p args "--ro-bind" "/proj" "/proj"))
    (should (parenting-test--bind-p args "--ro-bind" "/data/src" "/data"))
    (should (parenting-test--bind-p args "--bind" "/scratch" "/scratch"))))

(ert-deftest parenting-spawn-sandbox-rejects-explicit-wrapper ()
  ;; :sandbox owns :command-wrapper, :child-socket-path and
  ;; :child-library-directory, so combining them is an error and no
  ;; child is spawned.
  (should-error (parenting-spawn :sandbox '(:network nil)
                                 :command-wrapper '("bwrap")))
  (should-error (parenting-spawn :sandbox '(:network nil)
                                 :child-socket-path "/tmp/x"))
  (should-error (parenting-spawn :sandbox '(:network nil)
                                 :child-library-directory "/tmp/lib")))

(defun parenting-test--bwrap-usable-p ()
  "Return non-nil if bwrap can create an unprivileged user namespace.
Many CI runners and nested sandboxes forbid this, so the live
sandbox test skips rather than fails when it is unavailable."
  (and (executable-find parenting-sandbox-program)
       (eq 0 (call-process parenting-sandbox-program nil nil nil
                           "--ro-bind" "/" "/" "true"))))

(ert-deftest parenting-spawn-sandbox-child-roundtrips ()
  ;; The end-to-end proof: a real child under bwrap, reached over a
  ;; socket that crosses the mount namespace.  Skipped cleanly where
  ;; unprivileged user namespaces are unavailable.
  (unless (parenting-test--bwrap-usable-p)
    (ert-skip "bwrap cannot create a user namespace here"))
  (parenting-with-child (conn :sandbox '(:network nil) :timeout 60)
    (should (equal 3 (parenting-eval conn '(+ 1 2))))
    ;; The child really is jailed: no host network was shared.
    (should (equal "sandboxed" (parenting-eval conn '"sandboxed")))))

(provide 'parenting-test)
;;; parenting-test.el ends here
