;;;; cl-star.asd

(asdf:defsystem #:cl-star
  :description " STAR format (https://dasl.ing/star.html)  serializer/deserializer "
  :author "Sergio Garcia <sergio.garcia@gmail.com>"
  :license  "GPL 3.0"
  :version "0.0.1"
  :serial t
  :components ((:file "package")
               (:file "cl-star")))
