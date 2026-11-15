;;;; cl-star.asd

(asdf:defsystem #:cl-star
  :description " STAR format (https://dasl.ing/star.html)  serializer/deserializer "
  :author "Sergio Garcia <sergio.garcia@gmail.com>"
  :license  "GPL 3.0"
  :version "0.0.1"
  :serial t
  :components ((:file "package")
               (:file "cl-star")))

(asdf:defsystem #:cl-star/tests
  :description "Test suite for cl-star"
  :author "Sergio Garcia <sergio.garcia@gmail.com>"
  :license  "GPL 3.0"
  :version "0.0.1"
  :serial t
  :depends-on (#:cl-star)
  :components ((:file "tests"))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :cl-star/tests :run-tests)
               (error "cl-star tests failed."))))
