;;;; tests.lisp

;;; A small, dependency free test suite for cl-star.
;;; Run it through ASDF with:
;;;   (asdf:test-system :cl-star)

(defpackage #:cl-star/tests
  (:use #:cl #:cl-star)
  (:export #:run-tests))

(in-package #:cl-star/tests)

;;; ---------------------------------------------------------------------------
;;; Tiny test harness
;;; ---------------------------------------------------------------------------

(defvar *tests* '())
(defvar *failures* '())

(defmacro deftest (name &body body)
  "Defines a test function and registers it for RUN-TESTS."
  `(progn
     (defun ,name () ,@body)
     (pushnew ',name *tests* :test #'eq)))

(defmacro check (form expected)
  "Fails the current test unless FORM and EXPECTED are EQUALP."
  `(let ((actual ,form))
     (unless (equalp actual ,expected)
       (error "expected ~s to be ~s, got ~s" ',form ,expected actual))))

(defmacro check-raises (condition-type &body body)
  "Fails the current test unless BODY signals CONDITION-TYPE."
  `(let ((signaled nil))
     (handler-case (progn ,@body)
       (,condition-type (condition) (setf signaled condition)))
     (unless signaled
       (error "expected ~s to be signaled, nothing was" ',condition-type))))

;;; ---------------------------------------------------------------------------
;;; Helpers
;;; ---------------------------------------------------------------------------

(defun bytes (&rest values)
  "Builds a vector of octets out of VALUES."
  (let ((vector (make-array (length values) :element-type '(unsigned-byte 8))))
    (loop for value in values
          for i from 0
          do (setf (aref vector i) value))
    vector))

(defun string-bytes (string)
  "Returns the octets of STRING."
  (let ((vector (make-array (length string) :element-type '(unsigned-byte 8))))
    (loop for char across string
          for i from 0
          do (setf (aref vector i) (char-code char)))
    vector))

(defun hex-bytes (hex)
  "Parses a hex string such as \"2a6c0100\" into a vector of octets."
  (let ((vector (make-array (/ (length hex) 2) :element-type '(unsigned-byte 8))))
    (dotimes (i (length vector) vector)
      (setf (aref vector i)
            (parse-integer (subseq hex (* 2 i) (+ 2 (* 2 i))) :radix 16)))))

(defun temp-binary-file (name)
  (merge-pathnames name (uiop:ensure-directory-pathname (uiop:temporary-directory))))

(defun write-to-file (octets path)
  (with-open-file (stream path :direction :output :if-exists :supersede
                          :if-does-not-exist :create
                          :element-type '(unsigned-byte 8))
    (write-sequence octets stream))
  path)

(defun read-from-file (path)
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((buffer (make-array (file-length stream) :element-type '(unsigned-byte 8))))
      (read-sequence buffer stream)
      buffer)))

(defmacro with-temp-archive ((stream-var content-var) &body body)
  "Evaluates BODY with STREAM-VAR bound to a temporary binary output stream.
After the stream is closed the octets that were written are returned."
  `(let* ((path (temp-binary-file "cl-star-test.bin"))
          (,content-var nil))
     (with-open-file (,stream-var path :direction :output :if-exists :supersede
                     :if-does-not-exist :create
                     :element-type '(unsigned-byte 8))
       ,@body)
     (setf ,content-var (read-from-file path))
     ,content-var))

(defmacro with-bytes-stream ((var octets) &body body)
  "Evaluates BODY with VAR bound to a binary input stream over OCTETS."
  `(let ((path (temp-binary-file "cl-star-input.bin")))
     (write-to-file ,octets path)
     (with-open-file (,var path :direction :input :element-type '(unsigned-byte 8))
       ,@body)))

;;; The metadata used all over the tests: a DRISL map with a single "$type"
;;; key holding "demo".
(defparameter *demo-meta*
  (bytes #xA1 #x65 #x24 #x74 #x79 #x70 #x65 #x64 #x64 #x65 #x6D #x6F))

;;; The canonical example archive:
;;;   magic | len=12 | meta | 1 | len=8 | "some/key" | len=11 | "lorem ipsum" | 0
(defparameter *example-archive*
  (bytes #x2A #x6C #x01 #x00              ; magic
         #x0C                             ; metadata length
         #xA1 #x65 #x24 #x74 #x79 #x70 #x65 #x64 #x64 #x65 #x6D #x6F ; metadata
         #x01                             ; pair marker
         #x08                             ; key length
         #x73 #x6F #x6D #x65 #x2F #x6B #x65 #x79 ; "some/key"
         #x0B                             ; value length
         #x6C #x6F #x72 #x65 #x6D #x20 #x69 #x70 #x73 #x75 #x6D ; "lorem ipsum"
         #x00))                           ; end marker

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(deftest test-example-archive-bytes
  (check (with-temp-archive (stream content)
           (let ((writer (make-star-writer stream)))
             (write-star-meta writer *demo-meta*)
             (write-star-pair writer (string-bytes "some/key") (string-bytes "lorem ipsum"))
             (finish-star-writer writer)))
         *example-archive*))

(deftest test-empty-archive
  ;; magic | len=0 | end marker
  (check (with-temp-archive (stream content)
           (let ((writer (make-star-writer stream)))
             (write-star-meta writer (bytes))
             (finish-star-writer writer)))
         (bytes #x2A #x6C #x01 #x00 #x00 #x00)))

(deftest test-empty-key-and-value
  (check (with-temp-archive (stream content)
           (let ((writer (make-star-writer stream)))
             (write-star-meta writer (bytes))
             (write-star-pair writer (bytes) (bytes))
             (finish-star-writer writer)))
         (bytes #x2A #x6C #x01 #x00 #x00 #x01 #x00 #x00 #x00)))

(deftest test-duplicate-keys-are-kept
  (check (with-temp-archive (stream content)
           (let ((writer (make-star-writer stream)))
             (write-star-meta writer (bytes))
             (write-star-pair writer (string-bytes "k") (string-bytes "1"))
             (write-star-pair writer (string-bytes "k") (string-bytes "2"))
             (finish-star-writer writer)))
         (bytes #x2A #x6C #x01 #x00 #x00
                #x01 #x01 #x6B #x01 #x31
                #x01 #x01 #x6B #x01 #x32
                #x00)))

(deftest test-varint-encoding
  ;; The length of a value is encoded as a minimally encoded varint.
  (dolist (case '((0 "00") (1 "01") (127 "7f") (128 "8001") (16384 "808001")))
    (destructuring-bind (size prefix) case
      (let ((content
              (with-temp-archive (stream content)
                (let ((writer (make-star-writer stream)))
                  (write-star-meta writer (bytes))
                  (write-star-pair writer (bytes)
                                   (make-array size :element-type '(unsigned-byte 8)))
                  (finish-star-writer writer)))))
        ;; magic(4) + meta length(1) + pair marker(1) + key length(1)
        (check (subseq content 7 (+ 7 (/ (length prefix) 2)))
               (hex-bytes prefix))))))

(deftest test-varint-roundtrip
  (dolist (size '(0 1 127 128 129 16383 16384 100000))
    (let ((content
            (with-temp-archive (stream content)
              (let ((writer (make-star-writer stream)))
                (write-star-meta writer (bytes))
                (write-star-pair writer (bytes)
                                 (make-array size :element-type '(unsigned-byte 8)))
                (finish-star-writer writer)))))
      (with-bytes-stream (input content)
        (let ((archive (read-star input)))
          (check (length (car (first (star-archive-pairs archive)))) 0)
          (check (length (cdr (first (star-archive-pairs archive)))) size))))))

(deftest test-reader-rejects-non-minimal-varint
  ;; 0x81 0x00 encodes 1 in a non minimal way.
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x81 #x00))
      (read-star stream))))

(deftest test-reader-rejects-overlong-varint
  ;; Ten bytes are too many for a varint.
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00
                                     #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80 #x80))
      (read-star stream))))

(deftest test-reader-rejects-bad-magic
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x02 #x00))
      (read-star stream))))

(deftest test-reader-rejects-truncated-meta
  (check-raises star-truncated-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x0C #xA1 #x65 #x24 #x74 #x79))
      (read-star stream))))

(deftest test-reader-rejects-missing-end-marker
  ;; magic | len=0 and then EOF: the end marker never shows up.
  (check-raises star-truncated-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x00))
      (read-star stream))))

(deftest test-reader-rejects-truncated-pair
  (check-raises star-truncated-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x00 #x01 #x01 #x73))
      (read-star stream))))

(deftest test-reader-rejects-invalid-control-byte
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x00 #x02))
      (read-star stream))))

(deftest test-reader-rejects-trailing-bytes
  ;; A valid archive followed by garbage.
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x00 #x00 #xFF))
      (read-star stream))))

(deftest test-reader-honours-size-limits
  (check-raises star-size-limit-error
    (with-bytes-stream (stream *example-archive*)
      (read-star stream :max-value-size 4)))
  (check-raises star-size-limit-error
    (with-bytes-stream (stream *example-archive*)
      (read-star stream :max-key-size 4)))
  (check-raises star-size-limit-error
    (with-bytes-stream (stream *example-archive*)
      (read-star stream :max-meta-size 4))))

(deftest test-writer-honours-size-limits
  (with-temp-archive (stream content)
    (let ((writer (make-star-writer stream :max-meta-size 2)))
      (check-raises star-size-limit-error
        (write-star-meta writer *demo-meta*))))
  (with-temp-archive (stream content)
    (let ((writer (make-star-writer stream :max-key-size 2 :max-value-size 2)))
      (write-star-meta writer (bytes))
      (check-raises star-size-limit-error
        (write-star-pair writer (string-bytes "abc") (bytes)))
      (check-raises star-size-limit-error
        (write-star-pair writer (bytes) (string-bytes "abc"))))))

(deftest test-writer-state-machine
  (with-temp-archive (stream content)
    (let ((writer (make-star-writer stream)))
      ;; a pair cannot be written before the metadata
      (check-raises star-state-error
        (write-star-pair writer (bytes) (bytes)))
      ;; the metadata can only be written once
      (write-star-meta writer *demo-meta*)
      (check-raises star-state-error
        (write-star-meta writer *demo-meta*))
      (write-star-pair writer (bytes) (bytes))
      (finish-star-writer writer)
      ;; a finished writer refuses everything
      (check-raises star-state-error
        (write-star-pair writer (bytes) (bytes)))
      (check-raises star-state-error
        (finish-star-writer writer)))))

(deftest test-writer-requires-metadata
  (with-temp-archive (stream content)
    (let ((writer (make-star-writer stream)))
      (check-raises star-state-error
        (finish-star-writer writer))
      ;; ... unless the archive is aborted
      (finish-star-writer writer :abort t)
      (check (writer-state writer) :closed))))

(deftest test-writer-fails-on-io-error
  ;; Writing to a closed stream must poison the writer.
  (with-temp-archive (stream content)
    (let ((writer (make-star-writer stream)))
      (write-star-meta writer *demo-meta*)
      (close stream)
      (check-raises error (write-star-pair writer (bytes) (bytes)))
      (check (writer-state writer) :failed)
      ;; the failed writer cannot be used any more ...
      (check-raises star-state-error
        (write-star-pair writer (bytes) (bytes)))
      (check-raises star-state-error
        (finish-star-writer writer))
      ;; ... but it can be aborted
      (finish-star-writer writer :abort t)
      (check (writer-state writer) :closed))))

(deftest test-writer-rejects-wrong-types
  (with-temp-archive (stream content)
    (let ((writer (make-star-writer stream)))
      (write-star-meta writer *demo-meta*)
      (check-raises star-invalid-key-error
        (write-star-pair writer "not a vector" (bytes)))
      (check-raises star-type-mismatch
        (write-star-pair writer (bytes) "not a vector")))))

(deftest test-roundtrip
  (let* ((pairs (list (cons (string-bytes "a") (string-bytes "1"))
                      (cons (string-bytes "b") (bytes))
                      (cons (string-bytes "c") (string-bytes "3"))))
         (archive (make-star-archive *demo-meta* pairs))
         (content (with-temp-archive (stream content)
                    (write-star stream archive))))
    (with-bytes-stream (input content)
      (let ((read-back (read-star input)))
        (check (star-archive-meta read-back) *demo-meta*)
        (check (star-archive-pairs read-back) pairs)
        ;; writing the archive again yields the very same bytes
        (check (with-temp-archive (stream2 content2)
                 (write-star stream2 read-back))
               content)))))

(deftest test-reader-preserves-order
  (let ((pairs (loop for i from 0 below 20
                     collect (cons (string-bytes (format nil "key/~d" i))
                                   (string-bytes (format nil "value/~d" i))))))
    (let ((content (with-temp-archive (stream content)
                     (write-star stream (make-star-archive *demo-meta* pairs)))))
      (with-bytes-stream (input content)
        (let ((read-back (read-star input)))
          (check (star-archive-pairs read-back) pairs))))))

;;; ---------------------------------------------------------------------------
;;; Scenarios ported from the upstream interop vectors
;;; https://tangled.org/microcosm.blue/star/tree/interop/interop
;;;
;;; Those vectors target STAR-lite v1, whose layout has no 0x01 pair marker
;;; and no 0x00 end marker:
;;;
;;;   [ magic | len | meta ] [ len | key | len | val ] [ len | key | len | val ] ...
;;;
;;; while the current spec (https://dasl.ing/star.html) is
;;;
;;;   [ magic | len | meta ] [ 1 | len | key | len | val ] * [ 0 ]
;;;
;;; so the vectors cannot be fed to the reader as they are (every "valid" one
;;; would be rejected). The interesting cases are reproduced below in the
;;; current layout.
;;; ---------------------------------------------------------------------------

(deftest test-multi-byte-meta-length-prefix
  ;; A meta of 200 bytes needs a two byte varint length prefix (C8 01).
  (let* ((meta (make-array 200 :element-type '(unsigned-byte 8) :initial-element #x41))
         (content (with-temp-archive (stream content)
                    (let ((writer (make-star-writer stream)))
                      (write-star-meta writer meta)
                      (finish-star-writer writer)))))
    (check (subseq content 0 6) (bytes #x2A #x6C #x01 #x00 #xC8 #x01))
    (check (length content) 207)))

(deftest test-multi-byte-key-length-prefix
  ;; A key of 200 bytes needs a two byte varint length prefix (C8 01).
  (let* ((key (make-array 200 :element-type '(unsigned-byte 8) :initial-element #x44))
         (content (with-temp-archive (stream content)
                    (let ((writer (make-star-writer stream)))
                      (write-star-meta writer (bytes))
                      (write-star-pair writer key (bytes))
                      (finish-star-writer writer)))))
    ;; magic | meta length | pair marker | key length | key | value length | end
    (check (subseq content 0 8) (bytes #x2A #x6C #x01 #x00 #x00 #x01 #xC8 #x01))
    (check (subseq content (- (length content) 3)) (bytes #x44 #x00 #x00))))

(deftest test-multi-byte-value-length-prefix
  ;; A value of 300 bytes needs a two byte varint length prefix (AC 02).
  (let* ((value (make-array 300 :element-type '(unsigned-byte 8) :initial-element #x56))
         (content (with-temp-archive (stream content)
                    (let ((writer (make-star-writer stream)))
                      (write-star-meta writer (bytes))
                      (write-star-pair writer (bytes) value)
                      (finish-star-writer writer)))))
    ;; magic | meta length | pair marker | key length | value length | value | end
    (check (subseq content 7 9) (bytes #xAC #x02))))

(deftest test-nul-bytes-in-keys-and-values
  ;; NUL bytes are allowed in keys and values.
  (let* ((key (bytes #x00 #x41 #x00))
         (value (bytes #x00 #x42))
         (content (with-temp-archive (stream content)
                    (let ((writer (make-star-writer stream)))
                      (write-star-meta writer (bytes))
                      (write-star-pair writer key value)
                      (finish-star-writer writer)))))
    (with-bytes-stream (input content)
      (let* ((archive (read-star input))
             (pair (first (star-archive-pairs archive))))
        (check (car pair) key)
        (check (cdr pair) value)))))

(deftest test-non-sorted-keys-are-preserved
  ;; The format is ordered, not sorted.
  (let* ((pairs (list (cons (bytes #xFF) (bytes))
                       (cons (bytes #xAA) (bytes))))
         (content (with-temp-archive (stream content)
                    (write-star stream (make-star-archive (bytes) pairs)))))
    (with-bytes-stream (input content)
      (let ((archive (read-star input)))
        (check (mapcar #'car (star-archive-pairs archive))
               (list (bytes #xFF) (bytes #xAA)))))))

(deftest test-reader-rejects-non-minimal-key-length
  ;; 0x81 0x00 encodes the key length 1 in a non minimal way.
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x00 #x01 #x81 #x00 #x41 #x00))
      (read-star stream))))

(deftest test-reader-rejects-non-minimal-value-length
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x00 #x01 #x01 #x41 #x81 #x00 #x42))
      (read-star stream))))

(deftest test-reader-rejects-meta-with-too-short-length
  ;; The meta length prefix stops in the middle of the meta.
  (check-raises star-format-error
    (with-bytes-stream (stream (bytes #x2A #x6C #x01 #x00 #x07 #xA1 #x65 #x24 #x74 #x79 #x70 #x65))
      (read-star stream))))

;;; ---------------------------------------------------------------------------
;;; Runner
;;; ---------------------------------------------------------------------------

(defun run-tests ()
  "Runs every registered test. Returns true when they all pass."
  (let ((failures '())
        (passed 0))
    (dolist (test (reverse *tests*))
      (format t "~&[TEST] ~a" (symbol-name test))
      (handler-case
          (progn (funcall test)
                 (incf passed)
                 (format t " ... ok"))
        (error (condition)
          (push (cons (symbol-name test) condition) failures)
          (format t " ... FAIL: ~a" condition))))
    (format t "~&~&~d passed, ~d failed." passed (length failures))
    (dolist (failure (reverse failures))
      (format t "~&  ~a: ~a" (car failure) (cdr failure)))
    (null failures)))
