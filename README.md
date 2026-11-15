# cl-star

A Common Lisp reader and writer for the [STAR](https://dasl.ing/star.html)
(STreaming ARchive) format.

STAR is a simple container for byte string key/value pairs with a metadata
header. It is the format used by the [DASL](https://dasl.ing) specifications
and by atproto's public data exports.

```
|------ header ------| |--------- data pairs ---------| | end |
[ magic | len | meta ] [ 1 | len | key | len | val ] *  [  0  ]
```

* the magic is the fixed byte sequence `0x2A 0x6C 0x01 0x00`
* every length prefix is a minimally encoded unsigned
  [varint](https://github.com/multiformats/unsigned-varint) (at most 9 bytes)
* the metadata is a DRISL encoded map whose only reserved key is `"$type"`
* `0x01` introduces a data pair, `0x00` terminates the archive

## Metadata

The metadata is a DRISL encoded map whose only reserved key is `"$type"`, whose
value must be a text string. `cl-star` handles the container only: the
metadata is read and written as raw octets, so you are free to encode and
decode it with any DRISL implementation (e.g.
[cl-atproto-drisl](https://github.com/sgarciac/cl-atproto-drisl)).

Two rules are enforced by the container itself:

* the metadata must not be empty;
* it must be written (and read) exactly once, before any pair.

Validating the metadata is optional: hand a validator to the reader and it
will be called with the metadata octets, and its error will abort the read.

```lisp
(defun drisl-validator (octets)
  "Signals an error when OCTETS is not a canonical DRISL map with a $type."
  (let ((meta (cl-atproto-drisl:drisl-deserialize-from-sequence octets)))
    (unless (hash-table-p meta)
      (error "the metadata is not a DRISL map"))
    (unless (stringp (gethash "$type" meta))
      (error "the metadata has no $type string"))))

(cl-star:read-star stream :meta-validator #'drisl-validator)
```

## Installation

With [Quicklisp](https://beta.quicklisp.org), put the checkout in
`~/quicklisp/local-projects/` and then:

```lisp
(asdf:load-system :cl-star)
```

## Usage

### Writing an archive

```lisp
(require :asdf)
(asdf:load-system :cl-star)

;; optional: (use-package :cl-star) to drop the cl-star: prefixes

(defun octets (string)
  "Returns the octets of STRING."
  (let ((vector (make-array (length string) :element-type '(unsigned-byte 8))))
    (loop for char across string
          for i from 0
          do (setf (aref vector i) (char-code char)))
    vector))

;; The metadata: a DRISL map with a "$type" string. Here {"$type":"demo"}.
(defparameter *meta*
  (make-array 12 :element-type '(unsigned-byte 8)
              :initial-contents '(#xA1 #x65 #x24 #x74 #x79 #x70
                                  #x65 #x64 #x64 #x65 #x6D #x6F)))

(with-open-file (stream "/tmp/example.star"
                         :direction :output
                         :if-exists :supersede
                         :element-type '(unsigned-byte 8))
  (let ((writer (cl-star:make-star-writer stream)))
    ;; The metadata must be written first, exactly once.
    (cl-star:write-star-meta writer *meta*)
    ;; Then any number of key/value pairs.
    (cl-star:write-star-pair writer (octets "some/key") (octets "lorem ipsum"))
    ;; The end marker is written here; the stream is flushed, not closed.
    (cl-star:finish-star-writer writer)))
```

The resulting file is:

```text
2a6c0100 0c a16524747970656464656d6f 01 08 736f6d652f6b6579 0b 6c6f72656d20697073756d 00
```

### Reading an archive

```lisp
(with-open-file (stream "/tmp/example.star"
                         :direction :input
                         :element-type '(unsigned-byte 8))
  (let ((archive (cl-star:read-star stream)))
    ;; the metadata, as octets
    (cl-star:star-archive-meta archive)
    ;; the pairs, in order, as (key . value) conses
    (dolist (pair (cl-star:star-archive-pairs archive))
      (format t "~a -> ~a~%"
              (map 'string #'code-char (car pair))
              (map 'string #'code-char (cdr pair))))))
```

```text
some/key -> lorem ipsum
```

### Streaming API

When an archive is too big to be held in memory, use the reader directly:

```lisp
(let ((reader (cl-star:make-star-reader stream)))
  (cl-star:read-star-meta reader)            ; => metadata octets
  (loop
    (multiple-value-bind (key value) (cl-star:read-star-pair reader)
      ;; the key is NIL at the end of the archive
      (when (null key) (return))
      (format t "~a -> ~a~%" key value))))
```

### Writing a whole archive at once

```lisp
(cl-star:write-star stream
                   (cl-star:make-star-archive *meta*
                                             (list (cons (octets "a") (octets "1"))
                                                   (cons (octets "b") (octets "2")))))
```

## API

| Symbol | Description |
| --- | --- |
| `make-star-writer` | creates a writer over a binary output stream |
| `write-star-meta` | writes the magic number and the metadata (once) |
| `write-star-pair` | writes one key/value pair |
| `finish-star-writer` | writes the end marker (`:abort t` discards the archive) |
| `writer-state` | `:new`, `:pairs`, `:closed` or `:failed` |
| `make-star-reader` | creates a reader over a binary input stream |
| `read-star-meta` | reads the magic number and the metadata |
| `read-star-pair` | reads the next pair, `nil` at the end of the archive |
| `read-star` | reads a whole archive, returning a `star-archive` |
| `write-star` | writes a whole `star-archive` |
| `star-archive` | `meta` and `pairs` accessors |

Both `make-star-reader` and `read-star` accept a `:meta-validator` function,
called with the metadata octets; see [Metadata](#metadata).

Keys and values are vectors of `(unsigned-byte 8)`.

### Errors

All errors derive from `star-error`:

| Condition | Raised when |
| --- | --- |
| `star-format-error` | the archive is malformed (bad magic, bad control byte, trailing bytes, non minimal varint) |
| `star-truncated-error` | the archive ends prematurely |
| `star-size-limit-error` | a key, value or the metadata is bigger than the configured limit |
| `star-type-mismatch` | a value is not a vector of octets |
| `star-invalid-key-error` | a key is not a vector of octets |
| `star-state-error` | the writer or the reader is used in the wrong state |

Size limits can be configured per writer and per reader, they default to 8 KiB
per key, 5 MiB per value and 5 MiB of metadata.

## Interop

The test suite runs the test vectors of the reference implementation
(<https://tangled.org/bnewbold.net/cobalt/tree/main/star/testdata>), which are
the interop vectors of
<https://tangled.org/microcosm.blue/star/tree/interop/interop> updated to the
layout of the current specification. They are vendored in `tests/fixtures/`
and used by `tests/interop.lisp`:

* 18 valid archives: they must parse, and their pairs and metadata must match
  the expectation;
* 37 invalid archives: they must be rejected, 29 of them by the container
  parser and 8 of them because of their metadata.

The metadata of those archives is validated with `cl-atproto-drisl`, which the
test system depends on weakly: when it is not installed, the metadata checks
are skipped.

The interop vectors of the `microcosm.blue/star` repository itself target
STAR-lite **v1**, whose layout has no `0x01` pair marker and no `0x00` end
marker:

```
[ magic | len | meta ] [ len | key | len | val ] [ len | key | len | val ] ...
```

so they cannot be fed to a reader implementing the current spec.

## Tests

```lisp
(asdf:test-system :cl-star/tests)
```

## License

GPL 3.0
