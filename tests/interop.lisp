;;;; interop.lisp

;;; Interop tests, based on the test vectors of the reference implementation:
;;; https://tangled.org/bnewbold.net/cobalt/tree/main/star/testdata
;;;
;;; Those vectors are the interop vectors of
;;; https://tangled.org/microcosm.blue/star/tree/interop/interop, updated to
;;; the layout of the current specification:
;;;
;;;   [ magic | len | meta ] [ 1 | len | key | len | val ] * [ 0 ]
;;;
;;; The fixtures are vendored in tests/fixtures/.

(in-package #:cl-star/tests)

;;; ---------------------------------------------------------------------------
;;; A minimal JSON reader
;;; ---------------------------------------------------------------------------

(defun parse-json (string)
  "Parses the JSON text STRING.
Objects are returned as alists, arrays as vectors, strings as strings, numbers
as integers (or floats when they have a fraction or an exponent), true as T and
false and null as NIL."
  (let ((position 0)
        (length (length string)))
    (labels
        ((peek () (and (< position length) (char string position)))
         (advance () (prog1 (char string position) (incf position)))
         (skip-whitespace ()
           (loop while (and (peek)
                            (member (peek) '(#\Space #\Tab #\Newline #\Return)))
                 do (incf position)))
         (fail (message) (error "JSON error at offset ~d: ~a" position message))
         (expect (character)
           (unless (eql (peek) character)
             (fail (format nil "expected ~s" character)))
           (advance))
         (parse-hex-digit ()
           (let ((character (or (peek) (fail "unterminated escape"))))
             (advance)
             (or (digit-char-p character 16)
                 (fail (format nil "bad hex digit ~s" character)))))
         (parse-hex-4 ()
           (let ((value 0))
             (dotimes (i 4 value)
               (setf value (logior (ash value 4) (parse-hex-digit))))))
         (parse-escape ()
           "Reads the escape sequence after a backslash, returns its character."
           (let ((escape (or (peek) (fail "unterminated escape"))))
             (advance)
             (case escape
               (#\" #\")
               (#\\ #\\)
               (#\/ #\/)
               (#\b #\Backspace)
               (#\f #\Page)
               (#\n #\Newline)
               (#\r #\Return)
               (#\t #\Tab)
               (#\u (let ((code (parse-hex-4)))
                      (when (> code #xD7FF)
                        (fail "unsupported unicode escape"))
                      (code-char code)))
               (otherwise (fail (format nil "unknown escape ~s" escape))))))
         (parse-string ()
           (expect #\")
           (let ((characters '()))
             (loop
               (let ((character (or (peek) (fail "unterminated string"))))
                 (advance)
                 (cond ((eql character #\") (return))
                       ((eql character #\\) (push (parse-escape) characters))
                       (t (push character characters)))))
             (coerce (nreverse characters) 'string)))
         (parse-number ()
           (let ((start position))
             (when (eql (peek) #\-) (advance))
             (loop while (digit-char-p (peek)) do (advance))
             (let ((floatp (member (peek) '(#\. #\e #\E))))
               (when (eql (peek) #\.)
                 (advance)
                 (loop while (digit-char-p (peek)) do (advance)))
               (when (member (peek) '(#\e #\E))
                 (advance)
                 (when (member (peek) '(#\+ #\-)) (advance))
                 (loop while (digit-char-p (peek)) do (advance)))
               (let ((text (subseq string start position)))
                 (if floatp
                     (read-from-string text)
                     (parse-integer text))))))
         (parse-literal (literal value)
           (unless (and (>= (+ position (length literal)) length)
                        (string= literal string
                                  :start2 position
                                  :end2 (+ position (length literal))))
             (fail (format nil "expected ~s" literal)))
           (incf position (length literal))
           value)
         (parse-pair ()
           (let ((key (parse-string)))
             (skip-whitespace)
             (expect #\:)
             (skip-whitespace)
             (cons key (parse-value))))
         (parse-array ()
           (expect #\[)
           (skip-whitespace)
           (if (eql (peek) #\])
               (progn (advance) (vector))
               (let ((items '()))
                 (loop
                   (push (parse-value) items)
                   (skip-whitespace)
                   (if (eql (peek) #\])
                       (progn (advance) (return))
                       (progn (expect #\,) (skip-whitespace))))
                 (coerce (nreverse items) 'vector))))
         (parse-object ()
           (expect #\{)
           (skip-whitespace)
           (if (eql (peek) #\})
               (progn (advance) '())
               (let ((entries '()))
                 (loop
                   (push (parse-pair) entries)
                   (skip-whitespace)
                   (if (eql (peek) #\})
                       (progn (advance) (return))
                       (progn (expect #\,) (skip-whitespace))))
                 (nreverse entries))))
         (parse-value ()
           (skip-whitespace)
           (case (peek)
             (#\" (parse-string))
             (#\{ (parse-object))
             (#\[ (parse-array))
             (#\t (parse-literal "true" t))
             (#\f (parse-literal "false" nil))
             (#\n (parse-literal "null" nil))
             (otherwise (parse-number)))))
      (let ((value (parse-value)))
        (skip-whitespace)
        (when (peek) (fail "trailing data"))
        value))))

;;; ---------------------------------------------------------------------------
;;; Metadata validation, on top of cl-atproto-drisl
;;;
;;; cl-star does not validate the metadata by itself: it is DRISL agnostic.
;;; A validator can be handed to the reader, see :meta-validator.
;;; ---------------------------------------------------------------------------

(defun drisl-available-p ()
  "True when cl-atproto-drisl is available."
  (not (null (find-package :cl-atproto-drisl))))

(defun drisl-meta-validator (octets)
  "Signals an error when OCTETS is not a canonical DRISL map holding a $type
string, as the STAR specification requires."
  (unless (drisl-available-p)
    (error "cl-atproto-drisl is not available"))
  (let ((decoded (cl-atproto-drisl:drisl-deserialize-from-sequence octets)))
    (unless (hash-table-p decoded)
      (error "the metadata is not a DRISL map"))
    (dolist (key (loop for key being the hash-keys of decoded collect key))
      (unless (stringp key)
        (error "the metadata has a non text string key")))
    (let ((type (gethash "$type" decoded)))
      (unless (stringp type)
        (error "the metadata has no $type string")))
    ;; the encoding must be canonical: re-encoding the decoded metadata must
    ;; give back the very same bytes
    (let ((re-encoded (cl-atproto-drisl:drisl-serialize-to-sequence decoded)))
      (unless (equalp re-encoded octets)
        (error "the metadata is not canonically encoded")))))

;;; ---------------------------------------------------------------------------
;;; Fixture helpers
;;; ---------------------------------------------------------------------------

(defun fixture-path (name)
  (asdf:system-relative-pathname "cl-star/tests" (format nil "tests/fixtures/~a" name)))

(defun read-file-string (path)
  "Reads the whole file PATH and returns it as a string."
  (with-open-file (stream path :external-format :utf-8)
    (with-output-to-string (out)
      (loop for line = (read-line stream nil nil)
            while line
            do (write-string line out)
               (terpri out)))))

(defun load-fixtures (name)
  "Loads the JSON fixture file NAME and returns a list of fixtures.
Each fixture is a plist with the keys :comment, :star-hex and, for the valid
ones, :decoded-meta and :decoded-pairs."
  (let ((json (parse-json (read-file-string (fixture-path name)))))
    (map 'list (lambda (fixture)
                 (let ((decoded (cdr (assoc "decoded" fixture :test #'string=))))
                   (list :comment (cdr (assoc "comment" fixture :test #'string=))
                         :star-hex (cdr (assoc "star_hex" fixture :test #'string=))
                         :decoded-meta (when decoded
                                         (cdr (assoc "meta" decoded :test #'string=)))
                         :decoded-pairs (when decoded
                                          (map 'list
                                               (lambda (pair)
                                                 (cons (cdr (assoc "key_hex" pair :test #'string=))
                                                       (cdr (assoc "value_hex" pair :test #'string=))))
                                               (cdr (assoc "pairs" decoded :test #'string=)))))))
               json)))

(defun hex-to-octets (hex)
  "Parses the hex string HEX into a vector of octets."
  (let ((vector (make-array (/ (length hex) 2) :element-type '(unsigned-byte 8))))
    (dotimes (i (length vector) vector)
      (setf (aref vector i)
            (parse-integer (subseq hex (* 2 i) (+ 2 (* 2 i))) :radix 16)))))

(defun read-star-octets (octets &key meta-validator)
  "Reads a STAR archive out of the vector OCTETS."
  (with-bytes-stream (stream octets)
    (read-star stream :meta-validator meta-validator)))

(defun meta-value-equal-p (expected value)
  "True when the decoded DRISL VALUE matches the JSON EXPECTED value."
  (cond ((stringp expected) (and (stringp value) (string= expected value)))
        ((integerp expected) (and (integerp value) (= expected value)))
        ((and (vectorp expected) (zerop (length expected)))
         (and (vectorp value) (zerop (length value))))
        (t (equalp expected value))))

;;; ---------------------------------------------------------------------------
;;; Tests
;;; ---------------------------------------------------------------------------

(deftest test-interop-valid-fixtures
  (dolist (fixture (load-fixtures "valid-star-fixtures.json"))
    (let* ((octets (hex-to-octets (getf fixture :star-hex)))
           (expected-pairs (getf fixture :decoded-pairs))
           (archive (read-star-octets octets
                                       :meta-validator (when (drisl-available-p)
                                                         #'drisl-meta-validator)))
           (pairs (star-archive-pairs archive)))
      ;; the archive must parse
      (check (length pairs) (length expected-pairs))
      ;; the pairs must match, in order
      (loop for pair in pairs
            for expected in expected-pairs
            do (check (car pair) (hex-to-octets (car expected)))
               (check (cdr pair) (hex-to-octets (cdr expected))))
      ;; the metadata must hold the expected values
      (when (drisl-available-p)
        (let* ((decoded (cl-atproto-drisl:drisl-deserialize-from-sequence
                         (star-archive-meta archive)))
               (expected-meta (getf fixture :decoded-meta)))
          (check (hash-table-count decoded) (length expected-meta))
          (dolist (entry expected-meta)
            (let ((value (gethash (car entry) decoded)))
              (unless (meta-value-equal-p (cdr entry) value)
                (error "metadata key ~s is ~s, expected ~s"
                       (car entry) value (cdr entry))))))))))

(deftest test-interop-invalid-fixtures
  (let ((by-container 0)
        (by-drisl 0))
    (dolist (name '("invalid-star-fixtures.json" "invalid-star-fixtures-varint.json"))
      (dolist (fixture (load-fixtures name))
        (let* ((octets (hex-to-octets (getf fixture :star-hex)))
               (archive (handler-case
                            (read-star-octets octets)
                          (error () nil))))
          (if archive
              ;; the container is fine: the metadata must be invalid
              (when (drisl-available-p)
                (unless (handler-case
                            (progn (drisl-meta-validator (star-archive-meta archive))
                                   nil)
                          (error () t))
                  (error "the fixture was accepted: ~a" (getf fixture :comment)))
                ;; and reading it with the validator must fail
                (unless (handler-case
                            (progn (read-star-octets octets
                                                     :meta-validator #'drisl-meta-validator)
                                   nil)
                          (error () t))
                  (error "the fixture was accepted with the validator: ~a"
                         (getf fixture :comment)))
                (incf by-drisl))
              (incf by-container)))))
    (format t "~&       ~d fixtures rejected by the container, ~d by the DRISL validation"
            by-container by-drisl)))

(deftest test-interop-example-file
  (with-open-file (stream (fixture-path "example.star")
                          :direction :input
                          :element-type '(unsigned-byte 8))
    (let* ((archive (read-star stream))
           (pairs (star-archive-pairs archive)))
      (check (length pairs) 2)
      (check (map 'string #'code-char (car (first pairs))) "some/key")
      (check (map 'string #'code-char (cdr (first pairs))) "lorem ipsum")
      (check (map 'string #'code-char (car (second pairs))) "account/riley")
      ;; the metadata is a DRISL map with a $type
      (when (drisl-available-p)
        (let* ((decoded (cl-atproto-drisl:drisl-deserialize-from-sequence
                         (star-archive-meta archive)))
               (type (gethash "$type" decoded)))
          (check type "example-star-type"))))))
