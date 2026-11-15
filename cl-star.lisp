;;;; cl-star.lisp

;;; cl-star -- reader and writer for the STAR (STreaming ARchive) format.
;;;
;;; Specification: https://dasl.ing/star.html
;;;
;;; Layout of an archive:
;;;
;;;   [ magic | len | meta ] [ 1 | len | key | len | val ] * [ 0 ]
;;;
;;; * the magic is the fixed byte sequence 0x2A 0x6C 0x01 0x00
;;; * every length prefix is a minimally encoded unsigned varint (at most
;;;   9 bytes / 63 bits, see https://github.com/multiformats/unsigned-varint)
;;; * the metadata is a DRISL encoded map whose only reserved key is "$type"
;;; * 0x01 introduces a data pair, 0x00 terminates the archive

(in-package #:cl-star)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defconstant +magic-header+ #x2A6C0100)
(defconstant +pair-marker+ #x01) ; precedes every key/value pair
(defconstant +end-marker+  #x00) ; the final byte of the archive

;; Defaults borrowed from https://pkg.go.dev/tangled.org/bnewbold.net/cobalt/star#Writer
(defconstant +default-max-key-size+   (* 8 1024))
(defconstant +default-max-value-size+ (* 5 1024 1024))
(defconstant +default-max-meta-size+  (* 5 1024 1024))

;;; ---------------------------------------------------------------------------
;;; Conditions
;;; ---------------------------------------------------------------------------

(define-condition star-error (error) ())
(define-condition star-format-error (star-error) ())
(define-condition star-truncated-error (star-format-error) ())
(define-condition star-size-limit-error (star-format-error)
  ((limit :initarg :limit) (what :initarg :what)))
(define-condition star-type-mismatch (star-error)
  ((expected :initarg :expected) (actual :initarg :actual)))
(define-condition star-invalid-key-error (star-error) ())
(define-condition star-state-error      (star-error) ())

;;; ---------------------------------------------------------------------------
;;; Small helpers
;;; ---------------------------------------------------------------------------

(defun octet-vector-p (x)
  "True when X is a sequence of octets (a vector of unsigned bytes)."
  (and (vectorp x)
       (loop for byte across x
             always (typep byte '(unsigned-byte 8)))))

(defun check-octets (x what)
  "Signals a STAR-TYPE-MISMATCH unless X is a vector of octets.
WHAT is a keyword describing the role of X (e.g. :key, :value)."
  (unless (octet-vector-p x)
    (error 'star-type-mismatch
           :expected (format nil "~a: vector of (unsigned-byte 8)" what)
           :actual (type-of x)))
  x)

(defun read-octets (stream count)
  "Reads exactly COUNT octets from STREAM, returning them as a vector.
Signals a STAR-TRUNCATED-ERROR when the stream ends prematurely."
  (let ((buffer (make-array count :element-type '(unsigned-byte 8))))
    (unless (= count (read-sequence buffer stream))
      (error 'star-truncated-error
             :format-control "Unexpected EOF: wanted ~d octets, got fewer."
             :format-arguments (list count)))
    buffer))

;;; ---------------------------------------------------------------------------
;;; Varints
;;; ---------------------------------------------------------------------------

(defun write-varint (writer n)
  "Writes N to the stream of WRITER as a minimally encoded unsigned varint."
  (check-type n (unsigned-byte 63))
  (let ((buf (writer-scratch writer))
        (i 0))
    (loop
      (let ((byte (ldb (byte 7 0) n)))
        (setf n (ash n -7))
        (cond ((zerop n) (setf (aref buf i) byte) (incf i) (return))
              (t (setf (aref buf i) (logior byte #x80)) (incf i)))))
    (write-sequence buf (writer-stream writer) :end i)))

(defun read-varint (stream)
  "Reads a minimally encoded unsigned varint (at most 9 bytes) from STREAM.
Signals a STAR-TRUNCATED-ERROR at EOF and a STAR-FORMAT-ERROR for
over-long or non-minimal encodings."
  (let ((result 0))
    (loop for index from 0 below 9
          for byte = (read-byte stream nil nil)
          do
             (unless byte
               (error 'star-truncated-error
                      :format-control "Unexpected EOF while reading a varint."))
             (let ((payload (logand byte #x7f)))
               ;; Only the number zero may end in a 0x00 byte.
               (when (and (plusp index)
                          (zerop payload)
                          (zerop (logand byte #x80)))
                 (error 'star-format-error
                        :format-control "Non-minimal varint encoding."))
               (setf result
                     (logior result (ash payload (* index 7))))
               (when (zerop (logand byte #x80))
                 (return-from read-varint result))))
    (error 'star-format-error
           :format-control "Varint exceeds nine bytes.")))

;;; ---------------------------------------------------------------------------
;;; Writer
;;; ---------------------------------------------------------------------------
(defclass star-writer ()
  (
   ;; the underlying binary stream
   (stream :initarg :stream :reader writer-stream)

   ;; :new -(write metadata)-> :pairs -(close)-> :closed (unwind: :failed)
   (state :initform :new :accessor writer-state)

   ;; A reusable buffer for writing the lengths
   (scratch :initform (make-array 9 :element-type '(unsigned-byte 8))
            :reader writer-scratch)

   (max-key-size :initarg :max-key-size   :initform +default-max-key-size+   :accessor max-key-size)
   (max-value-size :initarg :max-value-size :initform +default-max-value-size+ :accessor max-value-size)
   (max-meta-size :initarg :max-meta-size  :initform +default-max-meta-size+  :accessor max-meta-size))

  (:documentation "Encoder for one STAR archive onto a binary output stream."))

(defun make-star-writer (stream &key max-key-size max-value-size max-meta-size)
  "Creates a new star-writer, initialized in the :new state"
  (apply #'make-instance 'star-writer :stream stream
         (append (when max-key-size   (list :max-key-size max-key-size))
                 (when max-value-size (list :max-value-size max-value-size))
                 (when max-meta-size  (list :max-meta-size max-meta-size)))))

(defmacro guarding-io ((writer) &body body)
  "If BODY exits non-locally, the stream may hold a partial record and poison the writer."
  (let ((ok (gensym "OK")))
    `(let ((,ok nil))
       (unwind-protect (multiple-value-prog1 (progn ,@body) (setf ,ok t))
         (unless ,ok (setf (writer-state ,writer) :failed))))))

(defun require-state (writer &rest allowed)
  "Helper function that verifies whether writer is in an accepted state. If not
   it throws a star-state-error."
  (unless (member (writer-state writer) allowed)
    (error 'star-state-error
           :format-control "Cannot do this while writer is ~s (needs ~{~s~^ or ~})."
           :format-arguments (list (writer-state writer) allowed))))

(defun write-magic (writer)
  (let ((s (writer-stream writer)))
    (loop for shift from 24 downto 0 by 8
	  do (write-byte (ldb (byte 8 shift) +magic-header+) s))))

(defun write-star-meta (writer octets)
  "Writes the magic number and the metadata octets.
The metadata must be a DRISL encoded map holding the required \"$type\" key.
This must be called exactly once, before any pair."
  (require-state writer :new)
  (check-octets octets :meta)
  (when (> (length octets) (max-meta-size writer))
      (error 'star-size-limit-error :what :meta :limit (max-meta-size writer)))
  (guarding-io (writer)
    (write-magic writer)
    (write-varint writer (length octets))
    (write-sequence octets (writer-stream writer))
    (setf (writer-state writer) :pairs)))

(defun write-marker (writer byte)
  (write-byte byte (writer-stream writer)))

(defun write-star-pair (writer key value)
  "Writes a single key/value pair. KEY and VALUE are vectors of octets.
Empty keys and values are allowed, as are duplicate keys."
  (require-state writer :pairs)
  (unless (octet-vector-p key)
    (error 'star-invalid-key-error
           :format-control "Invalid key: expected a vector of (unsigned-byte 8), got ~a."
           :format-arguments (list (type-of key))))
  (check-octets value :value)
  (let ((stream (writer-stream writer)))
    (when (> (length key) (max-key-size writer))
      (error 'star-size-limit-error :what :key :limit (max-key-size writer)))
    (when (> (length value) (max-value-size writer))
      (error 'star-size-limit-error :what :value :limit (max-value-size writer)))
    (guarding-io (writer)
      (write-marker writer +pair-marker+)
      (write-varint writer (length key))
      (write-sequence key stream)
      (write-varint writer (length value))
      (write-sequence value stream)))
  (values))

(defun finish-star-writer (writer &key abort)
  "Terminates the archive: writes the end marker and flushes the stream.
The underlying stream is not closed. When ABORT is true the archive is
discarded instead: no end marker is written, which is the only way out of
the :failed state."
  (ecase (writer-state writer)
    (:closed
     (unless abort
       (error 'star-state-error
              :format-control "Cannot finish a writer that is already closed."))
     nil)
    (:new
     (unless abort
       (error 'star-state-error
              :format-control "Cannot finish a writer that has no metadata."))
     (setf (writer-state writer) :closed))
    ((:pairs :failed)
     (cond (abort (setf (writer-state writer) :closed))
           ((eq (writer-state writer) :failed) (error 'star-state-error))
           (t (guarding-io (writer)
                (write-marker writer +end-marker+)
                (finish-output (writer-stream writer)))
              (setf (writer-state writer) :closed)))))
  (values))

;;; ---------------------------------------------------------------------------
;;; Reader
;;; ---------------------------------------------------------------------------
(defclass star-reader ()
  (
   ;; the underlying binary stream
   (stream :initarg :stream :reader reader-stream)

   ;; :new -(read metadata)-> :meta -(read pairs)-> :pairs -(end)-> :closed
   (state :initform :new :accessor reader-state)

   (max-key-size :initarg :max-key-size   :initform +default-max-key-size+   :accessor max-key-size)
   (max-value-size :initarg :max-value-size :initform +default-max-value-size+ :accessor max-value-size)
   (max-meta-size :initarg :max-meta-size  :initform +default-max-meta-size+  :accessor max-meta-size))

  (:documentation "Decoder for one STAR archive read from a binary input stream."))

(defun make-star-reader (stream &key max-key-size max-value-size max-meta-size)
  "Creates a new star-reader, initialized in the :new state."
  (apply #'make-instance 'star-reader :stream stream
         (append (when max-key-size   (list :max-key-size max-key-size))
                 (when max-value-size (list :max-value-size max-value-size))
                 (when max-meta-size  (list :max-meta-size max-meta-size)))))

(defun require-reader-state (reader &rest allowed)
  "Signals a STAR-STATE-ERROR unless READER is in one of the ALLOWED states."
  (unless (member (reader-state reader) allowed)
    (error 'star-state-error
           :format-control "Cannot do this while reader is ~s (needs ~{~s~^ or ~})."
           :format-arguments (list (reader-state reader) allowed))))

(defun read-magic (stream)
  "Reads and validates the four magic bytes of an archive."
  (let ((magic (read-octets stream 4)))
    (unless (and (= (aref magic 0) #x2A)
                 (= (aref magic 1) #x6C)
                 (= (aref magic 2) #x01)
                 (= (aref magic 3) #x00))
      (error 'star-format-error
             :format-control "Invalid STAR magic: ~{~2,'0x~^}."
             :format-arguments (list (coerce magic 'list))))
    magic))

(defun read-length-prefixed-octets (reader what)
  "Reads a varint length followed by that many octets, honouring the size
limits of READER. WHAT is a keyword describing the contents (:key, :value)."
  (let* ((length (read-varint (reader-stream reader)))
         (limit (case what
                  (:key (max-key-size reader))
                  (:value (max-value-size reader))
                  (t (error 'star-state-error
                            :format-control "Unknown length prefixed field ~s."
                            :format-arguments (list what))))))
    (when (> length limit)
      (error 'star-size-limit-error :what what :limit limit))
    (read-octets (reader-stream reader) length)))

(defun read-star-meta (reader)
  "Reads the magic number and the metadata of an archive.
Returns the metadata as a vector of octets."
  (require-reader-state reader :new)
  (read-magic (reader-stream reader))
  (let ((length (read-varint (reader-stream reader))))
    (when (> length (max-meta-size reader))
      (error 'star-size-limit-error :what :meta :limit (max-meta-size reader)))
    (let ((meta (read-octets (reader-stream reader) length)))
      (setf (reader-state reader) :meta)
      meta)))

(defun read-star-pair (reader)
  "Reads the next data pair of the archive.
Returns two values, the key and the value, both vectors of octets.
At the end of the archive returns NIL (and no other value); the reader then
sits in the :closed state."
  (require-reader-state reader :meta :pairs)
  (let ((control (read-byte (reader-stream reader) nil nil)))
    (unless control
      (error 'star-truncated-error
             :format-control "Unexpected EOF: the end of archive marker is missing."))
    (cond ((= control +end-marker+)
           (setf (reader-state reader) :closed)
           (values nil nil))
          ((= control +pair-marker+)
           (let ((key (read-length-prefixed-octets reader :key))
                 (value (read-length-prefixed-octets reader :value)))
             (setf (reader-state reader) :pairs)
             (values key value)))
          (t (error 'star-format-error
                    :format-control "Invalid control byte ~2,'0x."
                    :format-arguments (list control))))))

;;; ---------------------------------------------------------------------------
;;; Whole archives
;;; ---------------------------------------------------------------------------

(defstruct (star-archive
            (:constructor %make-star-archive (meta pairs))
            (:copier nil))
  (meta (make-array 0 :element-type '(unsigned-byte 8)) :type vector)
  (pairs '() :type list))

(defun make-star-archive (meta &optional pairs)
  "Builds a STAR-ARCHIVE out of the metadata octets and a list of
(key . value) pairs."
  (%make-star-archive (check-octets meta :meta) pairs))

(defun read-star (stream &key max-key-size max-value-size max-meta-size)
  "Reads a whole STAR archive from STREAM, returning a STAR-ARCHIVE.
Signals a STAR-FORMAT-ERROR when the archive is malformed and a
STAR-TRUNCATED-ERROR when it ends prematurely."
  (let* ((reader (make-star-reader stream
                                    :max-key-size max-key-size
                                    :max-value-size max-value-size
                                    :max-meta-size max-meta-size))
         (meta (read-star-meta reader))
         (pairs '()))
    (loop
      (multiple-value-bind (key value) (read-star-pair reader)
        (when (null key)
          (return))
        (push (cons key value) pairs)))
    ;; The end marker must not be followed by any other byte.
    (when (read-byte stream nil nil)
      (error 'star-format-error
             :format-control "Trailing bytes after the end of archive marker."))
    (%make-star-archive meta (nreverse pairs))))

(defun write-star (stream archive)
  "Writes the STAR-ARCHIVE ARCHIVE to STREAM."
  (let ((writer (make-star-writer stream)))
    (write-star-meta writer (star-archive-meta archive))
    (dolist (pair (star-archive-pairs archive))
      (write-star-pair writer (car pair) (cdr pair)))
    (finish-star-writer writer)
    (values)))
