;;; parenting-child.el --- Child side of parenting -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Child-side API of the parenting parent-child Emacs system.
;;
;; A child Emacs connects to a parent with `parenting-child-connect'
;; (or `parenting-child-start', which additionally serves forever in
;; batch sessions).  Once connected, the parent may evaluate arbitrary
;; forms here, and this Emacs may ask the parent to run functions with
;; `parenting-call-parent', subject to the parent's sandbox.

;;; Code:

(require 'parenting)
(require 'cl-lib)

(defvar parenting-child-connection nil
  "This Emacs's connection to its parent, when acting as a child.")

;;; Asynchronous tasks

(cl-defstruct (parenting-task (:constructor parenting--make-task)
                              (:copier nil))
  "A long-running unit of work the parent started in this Emacs."
  connection        ; the connection the task arrived on
  id                ; the task's id, shared with the parent
  done              ; non-nil once finished, failed, or cancelled
  cancel-function)  ; called if the parent cancels the task

(defvar parenting-current-task nil
  "The task handle, during the initial evaluation of a task form.
The form must capture it lexically (e.g. in a process sentinel or
timer callback) and eventually call `parenting-task-finish' or
`parenting-task-fail' on it.")

(defun parenting-task-finish (task value)
  "Complete TASK successfully with VALUE.
Does nothing if TASK is already finished, failed, or cancelled."
  (unless (parenting-task-done task)
    (setf (parenting-task-done task) t)
    (let ((conn (parenting-task-connection task)))
      (remhash (parenting-task-id task)
               (parenting-connection-tasks conn))
      (condition-case nil
          (parenting--send conn (list :type 'task-complete
                                      :task-id (parenting-task-id task)
                                      :outcome 'result
                                      :value value))
        (parenting-closed nil)))))

(defun parenting-task-fail (task error-symbol &optional data)
  "Complete TASK with an error named ERROR-SYMBOL carrying DATA.
Does nothing if TASK is already finished, failed, or cancelled."
  (unless (parenting-task-done task)
    (setf (parenting-task-done task) t)
    (let ((conn (parenting-task-connection task)))
      (remhash (parenting-task-id task)
               (parenting-connection-tasks conn))
      (condition-case nil
          (parenting--send conn (list :type 'task-complete
                                      :task-id (parenting-task-id task)
                                      :outcome 'error
                                      :error-symbol error-symbol
                                      :error-data data))
        (parenting-closed nil)))))

(defun parenting-task-on-cancel (task fn)
  "Call FN with no arguments if the parent cancels TASK.
Use it to kill the underlying process, cancel the timer, and so on."
  (setf (parenting-task-cancel-function task) fn))

(defun parenting--handle-task (conn message)
  "Start the asynchronous task carried by MESSAGE from the parent on CONN."
  (let* ((id (plist-get message :id))
         (task (parenting--make-task :connection conn :id id)))
    ;; Ack before evaluating, so the parent always sees the ack
    ;; before any completion — even one sent during this initial
    ;; evaluation.
    (parenting--respond conn id id)
    (puthash id task (parenting-connection-tasks conn))
    (condition-case err
        (let ((parenting-current-task task))
          (eval (plist-get message :form) t))
      (error (parenting-task-fail task (car err) (cdr err))))
    parenting--no-response))

(setf (alist-get '(child . task) parenting--request-handlers
                 nil nil #'equal)
      #'parenting--handle-task)

(defun parenting--handle-task-cancel (conn message)
  "Cancel the task MESSAGE names, if it is still running on CONN."
  (let* ((id (plist-get message :task-id))
         (task (gethash id (parenting-connection-tasks conn))))
    (when task
      (setf (parenting-task-done task) t)
      (remhash id (parenting-connection-tasks conn))
      (let ((cancel (parenting-task-cancel-function task)))
        (when cancel
          (ignore-errors (funcall cancel)))))))

(setf (alist-get '(child . task-cancel) parenting--notification-handlers
                 nil nil #'equal)
      #'parenting--handle-task-cancel)

(defun parenting--handle-eval (_conn message)
  "Evaluate the form carried by MESSAGE from the parent."
  (eval (plist-get message :form) t))

(setf (alist-get '(child . eval) parenting--request-handlers
                 nil nil #'equal)
      #'parenting--handle-eval)

;;;###autoload
(defun parenting-child-connect (socket)
  "Connect this Emacs, as a child, to the parent listening on SOCKET.
Return the connection, which is also stored in
`parenting-child-connection'."
  (let* ((process (make-network-process :name "parenting-parent"
                                        :family 'local
                                        :service socket
                                        :noquery t))
         (conn (parenting--setup-connection process 'child)))
    (setq parenting-child-connection conn)
    conn))

(defun parenting-child-serve (conn)
  "Handle parent requests on CONN until it closes.
In a batch session, exit Emacs once the parent disconnects."
  (let ((process (parenting-connection-process conn)))
    (while (process-live-p process)
      (accept-process-output process 1)))
  (when noninteractive
    (kill-emacs 0)))

;;;###autoload
(defun parenting-child-start (socket)
  "Connect to the parent on SOCKET; serve until the parent releases it.
This is the entry point `parenting-spawn' invokes in the child.  A
batch session serves inline and exits once the connection closes.
An interactive session (a daemon or visible-frame child) returns
the connection and serves from the normal event loop, but likewise
exits this Emacs when the connection closes: a spawned child is
owned by its parent, and on a remote machine nothing else would
reap it.  An Emacs that must survive its parent should attach with
`parenting-child-connect' instead."
  (let ((conn (parenting-child-connect socket)))
    (if noninteractive
        (parenting-child-serve conn)
      (add-hook 'parenting-connection-close-functions
                (lambda (closed)
                  (when (eq closed conn)
                    (kill-emacs 0))))
      conn)))

(defun parenting-call-parent (fn &optional args timeout)
  "Ask the parent to apply FN, a symbol, to the list ARGS.
The parent only complies if FN passes its sandbox; otherwise, and
when FN itself signals, this signals `parenting-remote-error'.
TIMEOUT overrides `parenting-default-timeout'."
  (let ((conn parenting-child-connection))
    (unless (and conn (parenting-connection-live-p conn))
      (signal 'parenting-closed (list "not connected to a parent")))
    (parenting--response-value
     (parenting--roundtrip conn (list :type 'call :fn fn :args args)
                           timeout))))

(provide 'parenting-child)
;;; parenting-child.el ends here
