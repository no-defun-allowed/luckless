#|
 This file is a part of Luckless
 (c) 2018 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

;;; hashtable.lisp
(in-package #:org.shirakumo.luckless.hashtable)
(docs:define-docs
  (defun make-castable
    "Make a castable, with the given test, size and hash function.
The hash function is called with a key object, and is expected to return a fixnum.
The size is rounded up to the next power of 2.")
  (defun castable-p
    "A predicate that is satisfied when given a castable.")
  (defun size
    "The number of associations a castable can currently store.")
  (defun count
    "The count of associations a castable has.")
  (defun test
    "The test function used by a castable.")
  (defun hash-function
    "The hash function used by a castable.")
  (defun gethash
    "Retrieve a value from a castable; like CL:GETHASH, it will return the value and T as multiple values if a value is found, or the default value (itself defaulting to NIL) and NIL if a value is not found.")
  (defun remhash
    "Removes an association from a castable, returning T if an association was removed, or NIL if there was no association to remove.")
  (defun try-remhash
    "Removes an association if it exists with the value provided, returning a value like REMHASH does.")
  (defun put-if-absent
    "Adds an association if one was not present already, returning T if an association was added, or NIL if one was not.")
  (defun put-if-equal
    "Updates an association if one exists with the given value, returning T if it was updated, or NIL if it was not, or doesn't exist.")
  (defun put-if-present
    "Updates an association if it exists, returning a value like PUT-IF-EQUAL does.")
  (defun clrhash
    "Removes all the associations from a castable.")
  (defun maphash
    "Call a function with each key and value association in the castable."))

;;; list.lisp
(in-package #:org.shirakumo.luckless.list)
(docs:define-docs
  (defun caslist
    "Make a caslist out of all the given values, like CL:LIST.")
  (defun caslist-p
    "A predicate that is satisfied when given a caslist.")
  (defun mapc
    "Call a function with every element in a caslist, returning the original caslist.")
  (defun first
    "Return the first element in a caslist.")
  (defun nth
    "Return the nth value in a caslist, or NIL if the list is shorter than N.")
  (defun length
    "Return the length of a caslist.")
  (defun to-list
    "Convert a caslist to a normal list.")
  (defun delete
    "Remove the first instance of VALUE in the caslist (according to the test, defaulting to #'EQL), modifying the caslist and returning it.")
  (defun member
    "Is the value an element of the caslist (according to the test, defaulting to #'EQL)?")
  (defun push
    "Push a value at the start of the caslist, modifying the caslist in place (unlike CL:PUSH, which doesn't modify list structure)."))
  
