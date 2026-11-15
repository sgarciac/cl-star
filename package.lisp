;;;; package.lisp

(defpackage #:cl-star
  (:use #:cl)
  (:export
   ;; archives
   :star-archive
   :make-star-archive
   :star-archive-meta
   :star-archive-pairs
   :read-star
   :write-star
   ;; writer
   :star-writer
   :make-star-writer
   :write-star-meta
   :write-star-pair
   :finish-star-writer
   :writer-state
   ;; reader
   :star-reader
   :make-star-reader
   :read-star-meta
   :read-star-pair
   :reader-state
   ;; errors
   :star-error
   :star-format-error
   :star-truncated-error
   :star-size-limit-error
   :star-type-mismatch
   :star-invalid-key-error
   :star-state-error
   ))
