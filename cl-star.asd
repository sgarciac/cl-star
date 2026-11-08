;;;; cl-star.asd

(asdf:defsystem #:cl-star
  :description "Describe cl-star here"
  :author "Your Name <your.name@example.com>"
  :license  "Specify license here"
  :version "0.0.1"
  :serial t
  :depends-on (#:cl-atproto-drisl)
  :components ((:file "package")
               (:file "cl-star")))
