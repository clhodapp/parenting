;;; parenting.el --- Parent-child remote control over a private socket -*- lexical-binding: t -*-

;; Copyright (C) 2026 Chris Hodapp

;; Author: Chris Hodapp <chris@hodapp.email>
;; Assisted-by: Claude:claude-fable-5
;; Maintainer: Chris Hodapp <chris@hodapp.email>
;; URL: https://github.com/clhodapp/parenting
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: processes, tools
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;; Distributed under the MIT license; see the LICENSE file.

;;; Commentary:
;; Core protocol shared by the parent and child sides of a
;; parent-child Emacs pair.  A parent Emacs remote-controls a child
;; Emacs over a private Unix domain socket: the parent may evaluate
;; arbitrary forms in the child, while the child may only invoke
;; functions in the parent that pass the parent's sandbox (an
;; allowlist with optional per-function argument predicates plus
;; global guard functions).
;;
;; Messages are plists printed with `prin1' and read back with
;; `read'.  Values that cannot be printed readably (buffers, windows,
;; processes, ...) are replaced by their printed representation as a
;; string, so results always deserialize cleanly on the other side.
;;
;; See `parenting-parent' for the parent-side API (`parenting-spawn',
;; `parenting-listen', `parenting-eval', the sandbox) and
;; `parenting-child' for the child side (`parenting-child-connect',
;; `parenting-call-parent').

;;; Code:

(require 'cl-lib)

(defconst parenting-protocol-version 1
  "Version of the parenting wire protocol spoken by this library.")

(defgroup parenting nil
  "Remote control of a child Emacs from a parent Emacs."
  :group 'processes
  :prefix "parenting-")

(defcustom parenting-default-timeout 30
  "Seconds to wait for the other Emacs before signaling `parenting-timeout'."
  :type 'number
  :group 'parenting)

(define-error 'parenting-error "Parenting error")
(define-error 'parenting-timeout
              "Timed out waiting for the other Emacs" 'parenting-error)
(define-error 'parenting-remote-error
              "Error signaled in the other Emacs" 'parenting-error)
(define-error 'parenting-forbidden
              "Call rejected by the parent sandbox" 'parenting-error)
(define-error 'parenting-closed
              "Connection to the other Emacs is closed" 'parenting-error)
(define-error 'parenting-cancelled
              "Task was cancelled" 'parenting-error)
(define-error 'parenting-backpressure
              "Too many polled task results are outstanding or unclaimed"
              'parenting-error)

(defvar parenting-connection-close-functions nil
  "Abnormal hook run with a connection when it closes.")

(cl-defstruct (parenting-connection (:constructor parenting--make-connection)
                                    (:copier nil))
  "A live link between a parent Emacs and a child Emacs."
  process           ; network process carrying the protocol stream
  role              ; symbol `parent' or `child': our side of the link
  buffer            ; hidden buffer accumulating unparsed input
  (next-id 0)       ; id of the most recently sent request
  (pending (make-hash-table :test #'eql)) ; id -> response callback
  peer-info         ; hello plist received from the other side
  allowed-functions ; parent side: alist of (FUNCTION . PREDICATE)
  guard-functions   ; parent side: list of (FN ARGS) guard functions
  (tasks (make-hash-table :test #'eql)) ; live tasks: parent side
                    ; id -> (CALLBACK . ERRBACK), child side id -> handle
  task-history      ; parent side: bounded ring of recent task events
  task-results      ; parent side: bounded ring of unclaimed results
  child-process     ; the spawned child process, when we own one
  server            ; the listening server process, when we own one
  socket-directory  ; private directory to delete on shutdown
  remote-directory) ; scratch directory on the child's machine, when remote

(defvar parenting--request-handlers nil
  "Alist mapping (ROLE . TYPE) to request handler functions.
Each handler is called with the connection and the request plist and
returns the value to send back.  Requests whose type has no handler
for the local role are answered with a `parenting-forbidden' error,
which is what confines the child to sandboxed `call' requests.")

(defvar parenting--notification-handlers nil
  "Alist mapping (ROLE . TYPE) to one-way message handlers.
Unlike request handlers, these send no response.  Notifications
whose type has no handler for the local role are ignored.")

(defconst parenting--no-response (make-symbol "parenting--no-response")
  "Sentinel a request handler returns after responding by itself.")

;;; Serialization

(defun parenting--sanitize (value seen)
  "Return VALUE with unreadable objects replaced by description strings.
SEEN maps already-visited structures to their sanitized copies, so
shared structure and cycles survive and are rendered by
`print-circle'.  Strings are stripped of text properties, whose
values need not be readable."
  (cond
   ((or (null value) (symbolp value) (numberp value)) value)
   ((stringp value) (substring-no-properties value))
   ((gethash value seen))
   ((consp value)
    (let ((copy (cons nil nil)))
      (puthash value copy seen)
      (setcar copy (parenting--sanitize (car value) seen))
      (setcdr copy (parenting--sanitize (cdr value) seen))
      copy))
   ((vectorp value)
    (let ((copy (make-vector (length value) nil)))
      (puthash value copy seen)
      (dotimes (i (length value))
        (aset copy i (parenting--sanitize (aref value i) seen)))
      copy))
   ((recordp value)
    (let ((copy (copy-sequence value)))
      (puthash value copy seen)
      (dotimes (i (length copy))
        (aset copy i (parenting--sanitize (aref copy i) seen)))
      copy))
   ((hash-table-p value)
    (let ((copy (make-hash-table :test (hash-table-test value))))
      (puthash value copy seen)
      (maphash (lambda (k v)
                 (puthash (parenting--sanitize k seen)
                          (parenting--sanitize v seen)
                          copy))
               value)
      copy))
   ((bool-vector-p value) value)
   (t (format "%S" value))))

(defun parenting--inert-p (value seen)
  "Return non-nil for a VALUE made only of inert data types.
The reader can construct callable byte-code objects from #[...]
literals, which a hostile peer could smuggle into the arguments of
an allowlisted higher-order function.  Every incoming message must
therefore consist solely of plain data: numbers, symbols, strings,
conses, vectors, records, hash tables, and bool-vectors.  SEEN
tracks visited structures so circular input terminates."
  (cond
   ((or (null value) (symbolp value) (numberp value) (stringp value)
        (bool-vector-p value))
    t)
   ((gethash value seen) t)
   ((consp value)
    (puthash value t seen)
    (and (parenting--inert-p (car value) seen)
         (parenting--inert-p (cdr value) seen)))
   ((vectorp value)
    (puthash value t seen)
    (cl-every (lambda (element) (parenting--inert-p element seen)) value))
   ((recordp value)
    (puthash value t seen)
    (cl-loop for i below (length value)
             always (parenting--inert-p (aref value i) seen)))
   ((hash-table-p value)
    (puthash value t seen)
    (catch 'parenting--not-inert
      (maphash (lambda (k v)
                 (unless (and (parenting--inert-p k seen)
                              (parenting--inert-p v seen))
                   (throw 'parenting--not-inert nil)))
               value)
      t))
   (t nil)))

(defun parenting--print-to-string (value)
  "Print VALUE readably, replacing unreadable objects with strings."
  (let ((print-circle t)
        (print-length nil)
        (print-level nil)
        (print-quoted t)
        (print-gensym t)
        ;; Keep every message on one physical line: a transport that
        ;; involves a pty or a remote shell may translate or swallow
        ;; raw control characters inside string literals.
        (print-escape-newlines t)
        (print-escape-control-characters t))
    (prin1-to-string
     (parenting--sanitize value (make-hash-table :test #'eq)))))

;;; Connection lifecycle

(defun parenting--setup-connection (process role)
  "Wrap network PROCESS in a connection whose local side is ROLE.
Installs the protocol filter and sentinel and sends the hello
message announcing ROLE to the other side."
  (let ((conn (parenting--make-connection
               :process process
               :role role
               :buffer (generate-new-buffer " *parenting*"))))
    (process-put process 'parenting-connection conn)
    (set-process-filter process #'parenting--filter)
    (set-process-sentinel process #'parenting--sentinel)
    (set-process-query-on-exit-flag process nil)
    (parenting--send conn (list :type 'hello
                                :protocol parenting-protocol-version
                                :role role
                                :emacs-version emacs-version))
    conn))

(defun parenting-connection-live-p (conn)
  "Return non-nil if connection CONN can still carry messages."
  (and (parenting-connection-p conn)
       (process-live-p (parenting-connection-process conn))))

(defun parenting-peer-emacs-version (conn)
  "Return the variable `emacs-version' of the Emacs on the other end of CONN.
Return nil if the hello message has not arrived yet."
  (plist-get (parenting-connection-peer-info conn) :emacs-version))

(defun parenting--on-close (conn)
  "Release the resources of CONN and fail all pending requests."
  (let ((pending (parenting-connection-pending conn))
        (callbacks nil))
    (maphash (lambda (_id callback) (push callback callbacks)) pending)
    (clrhash pending)
    (dolist (callback callbacks)
      (funcall callback (list :type 'error
                              :error-symbol 'parenting-closed
                              :error-data nil))))
  (when (buffer-live-p (parenting-connection-buffer conn))
    (kill-buffer (parenting-connection-buffer conn)))
  (run-hook-with-args 'parenting-connection-close-functions conn))

(defun parenting-shutdown (conn)
  "Close CONN, along with any owned child process and server socket."
  (let ((process (parenting-connection-process conn))
        (child (parenting-connection-child-process conn))
        (server (parenting-connection-server conn))
        (directory (parenting-connection-socket-directory conn))
        (remote (parenting-connection-remote-directory conn)))
    (when (process-live-p process)
      (delete-process process))
    (when (and child (process-live-p child))
      ;; A batch child exits by itself once the socket closes; give it
      ;; a moment before resorting to killing it.
      (with-timeout (2 nil)
        (while (process-live-p child)
          (accept-process-output nil 0.05)))
      (when (process-live-p child)
        (delete-process child)))
    (when (and server (process-live-p server))
      (delete-process server))
    (when (and directory (file-directory-p directory))
      (delete-directory directory t))
    ;; The remote scratch directory is reached over TRAMP, whose
    ;; connection may be gone along with the machine; never let its
    ;; cleanup wedge or fail the shutdown.
    (when remote
      (ignore-errors
        (with-timeout (10 nil)
          (when (file-directory-p remote)
            (delete-directory remote t)))))))

;;; Wire protocol

(defun parenting--send (conn message)
  "Send MESSAGE, a plist, over CONN."
  (let ((process (parenting-connection-process conn)))
    (unless (and process (process-live-p process))
      (signal 'parenting-closed (list conn)))
    (process-send-string process
                         (concat (parenting--print-to-string message) "\n"))))

(defun parenting--filter (process string)
  "Accumulate STRING from PROCESS and dispatch complete messages."
  (let ((conn (process-get process 'parenting-connection)))
    (when conn
      (with-current-buffer (parenting-connection-buffer conn)
        (goto-char (point-max))
        (insert string))
      (let ((message nil))
        (catch 'parenting--closed
          (while (setq message (parenting--read-message conn))
            ;; A message smuggling non-inert objects (e.g. #[...]
            ;; byte-code literals) marks the peer as hostile or
            ;; broken; drop the connection.
            (unless (parenting--inert-p
                     message (make-hash-table :test #'eq))
              (delete-process (parenting-connection-process conn))
              (throw 'parenting--closed nil))
            (parenting--dispatch conn message)))))))

(defun parenting--read-message (conn)
  "Read one complete message from CONN's buffer, or return nil."
  (let ((buffer (parenting-connection-buffer conn)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-min))
        (condition-case nil
            (let ((message (read (current-buffer))))
              (delete-region (point-min) (point))
              message)
          (end-of-file nil)
          ;; Anything else means the stream is corrupt; drop the
          ;; connection rather than trying to resynchronize.
          (error (delete-process (parenting-connection-process conn))
                 nil))))))

(defun parenting--sentinel (process _event)
  "Clean up the connection attached to PROCESS once it dies."
  (unless (process-live-p process)
    (let ((conn (process-get process 'parenting-connection)))
      (when conn
        (process-put process 'parenting-connection nil)
        (parenting--on-close conn)))))

;;; Dispatch

(defun parenting--dispatch (conn message)
  "Route one incoming MESSAGE on CONN."
  (pcase (plist-get message :type)
    ((or 'result 'error)
     (let* ((id (plist-get message :id))
            (callback (gethash id (parenting-connection-pending conn))))
       (when callback
         (remhash id (parenting-connection-pending conn))
         (funcall callback message))))
    ('hello
     (setf (parenting-connection-peer-info conn) message))
    (type
     (let ((notification
            (cdr (assoc (cons (parenting-connection-role conn) type)
                        parenting--notification-handlers))))
       (if notification
           (funcall notification conn message)
         (parenting--handle-request conn message))))))

(defun parenting--handle-request (conn message)
  "Run the role-appropriate handler for MESSAGE on CONN and respond."
  (let* ((type (plist-get message :type))
         (id (plist-get message :id))
         (role (parenting-connection-role conn))
         (handler (cdr (assoc (cons role type) parenting--request-handlers))))
    (cond
     ((null handler)
      (when id
        (parenting--respond-error
         conn id 'parenting-forbidden
         (list (format "%s requests are not accepted by a %s" type role)))))
     (t
      (condition-case err
          (let ((value (funcall handler conn message)))
            (unless (eq value parenting--no-response)
              (parenting--respond conn id value)))
        (error
         (parenting--respond-error conn id (car err) (cdr err))))))))

(defun parenting--respond (conn id value)
  "Send VALUE as the successful response to request ID on CONN."
  (parenting--send conn (list :type 'result :id id :value value)))

(defun parenting--respond-error (conn id symbol data)
  "Send error SYMBOL with DATA as the response to request ID on CONN."
  (parenting--send conn (list :type 'error :id id
                              :error-symbol symbol
                              :error-data data)))

;;; Requests

(defun parenting--send-request (conn message callback)
  "Send request MESSAGE on CONN; call CALLBACK with the response plist."
  (let ((id (cl-incf (parenting-connection-next-id conn))))
    (puthash id callback (parenting-connection-pending conn))
    (condition-case err
        (parenting--send conn (append message (list :id id)))
      (error
       (remhash id (parenting-connection-pending conn))
       (signal (car err) (cdr err))))
    id))

(defun parenting--response-value (response)
  "Return the value carried by RESPONSE, signaling remote errors."
  (pcase (plist-get response :type)
    ('result (plist-get response :value))
    ('error (signal 'parenting-remote-error
                    (list (plist-get response :error-symbol)
                          (plist-get response :error-data))))))

(defun parenting--roundtrip (conn message &optional timeout)
  "Send request MESSAGE on CONN and wait for its response plist.
Wait at most TIMEOUT seconds (`parenting-default-timeout' when nil)
before signaling `parenting-timeout'."
  (let* ((response nil)
         (process (parenting-connection-process conn))
         (deadline (+ (float-time) (or timeout parenting-default-timeout)))
         (id (parenting--send-request
              conn message (lambda (r) (setq response r)))))
    (while (and (null response) (process-live-p process))
      (when (> (float-time) deadline)
        (remhash id (parenting-connection-pending conn))
        (signal 'parenting-timeout (list message)))
      (accept-process-output process 0.05))
    (unless response
      (signal 'parenting-closed (list conn)))
    response))

(provide 'parenting)
;;; parenting.el ends here
