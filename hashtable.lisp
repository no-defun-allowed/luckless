#|
 This file is a part of Luckless
 (c) 2018 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>

 Based on:
   A Lock-Free Wait-Free Hash Table
   Cliff Click, Azul Systems, 2007
     https://github.com/boundary/high-scale-lib/blob/master/src/main/java/org/cliffc/high_scale_lib/NonBlockingHashMap.java
|#

(in-package #:org.shirakumo.luckless.hashtable)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defstruct (prime
              (:constructor prime (value)))
    (value NIL :type T))
  (defmethod make-load-form ((prime prime) &optional environment)
    (declare (ignore environment))
    `(prime 'prime)))

(defconstant max-spin 2)
(defconstant reprobe-limit 50)
(defconstant min-size-log 8)
(defconstant min-size (ash 1 min-size-log))
(defconstant no-match-old 'no-match-old)
(defconstant match-any 'match-any)
(defconstant tombstone 'tombstone)
(defconstant tombprime (if (boundp 'tombprime) tombprime (prime tombstone)))
(defconstant no-value 'no-value)

(declaim (ftype (function (unsigned-byte) fixnum) rehash)
         (inline rehash))

;; L71, int hash(Object)
;; The "spreading" done by the old REHASH seems to make things worse
;; on SBCL. It might have improved Java hashes, but this ain't Java.
(defun rehash (h) h)

(declaim (inline reprobe-limit))
(defun reprobe-limit (len)
  (+ REPROBE-LIMIT (ash len -2)))

;; L713, private class CHM
;; "The control structure for the NonBlockingHashMap"
(defstruct (chm
            (:constructor make-chm (size))
            (:conc-name %chm-))
  (size (error "no size?") :type counter)
  (slots (make-counter) :type counter)
  (newkvs NIL :type (or null simple-vector))
  (resizers 0 :type fixnum)
  (copy-idx 0 :type fixnum)
  (copy-done 0 :type fixnum))
(declaim (ftype (function (chm) fixnum)
                %chm-resizers %chm-copy-idx %chm-copy-done))

;; L716, int size()
(declaim (inline chm-size))
(defun chm-size (chm)
  (counter-value (%chm-size chm)))

;; L729, int slots()
(declaim (inline chm-slots))
(defun chm-slots (chm)
  (counter-value (%chm-slots chm)))

(declaim (inline cas-newkvs))
;; L742, boolean CAS_newkvs(Object[])
(defun cas-newkvs (chm newkvs)
  (loop while (null (%chm-newkvs chm))
        do (when (cas (%chm-newkvs chm) NIL newkvs)
             (return T))
        finally (return NIL)))

;; Heuristic to test if the table is too full and we should make a new one.
(declaim (inline table-full-p))
;; L780, boolean tableFull(int, int)
(defun table-full-p (chm reprobe-cnt len)
  (and (<= REPROBE-LIMIT reprobe-cnt)
       (<= (reprobe-limit len) (counter-value~ (%chm-slots chm)))))

(defstruct (castable
            (:constructor %make-castable (kvs last-resize test hasher))
            (:conc-name %castable-))
  (kvs (error "no KVS?") :type simple-vector)
  (last-resize (error "no LAST-RESIZE?") :type fixnum)
  (reprobes (make-counter) :type counter)
  (test (error "no TEST?") :type (function (T T) boolean))
  (hasher (error "no HASHER?") :type (function (T) fixnum)))

(declaim (inline chm))
(declaim (ftype (function (simple-vector) chm) chm))
;; L138, static CHM chm(Object[])
(declaim (inline chm)
         (ftype (function (simple-vector) chm) chm))
(defun chm (kvs)
  (svref kvs 0))

(declaim (inline hashes)
         (ftype (function (simple-vector) (simple-array fixnum)) hashes))
;; L139, static int[] hashes(Object[]) 
(defun hashes (kvs)
  (svref kvs 1))

(declaim (inline len)
         (ftype (function (simple-vector) (unsigned-byte 32)) len))
;; L140, static int len(Object[])
(defun len (kvs)
  (the (unsigned-byte 32) (ash (- (length kvs) 2) -1)))

(declaim (inline key)
         (ftype (function (simple-vector (unsigned-byte 32)) T) key))
;; L175 static Object key(Object[], int)
(defun key (kvs idx)
  (svref kvs (+ 2 (ash idx 1))))

(declaim (inline val)
         (ftype (function (simple-vector (unsigned-byte 32)) T) val))
;; L176 static Object val(Object[], int)
(defun val (kvs idx)
  (svref kvs (+ 3 (ash idx 1))))

(declaim (inline cas-key))
;; L177 static boolean CAS_key(Object[], int, Object, Object)
(defun cas-key (kvs idx old key)
  (declare (simple-vector kvs))
  (cas (svref kvs (+ 2 (ash idx 1))) old key))

(declaim (inline cas-val))
;; L180 static boolean CAS_val(Object[], int, Object, Object)
(defun cas-val (kvs idx old val)
  (declare (simple-vector kvs))
  (cas (svref kvs (+ 3 (ash idx 1))) old val))

;; L237 long reprobes()
(defun reprobes (table)
  (prog1 (counter-value (%castable-reprobes table))
    (setf (%castable-reprobes table) (make-counter))))

(defun determine-hasher (test)
  (or (cond ((eq test #'eq)
             #+sbcl #'sb-impl::eq-hash
             #+ccl #'ccl::%%eqhash)
            ((eq test #'eql)
             #+sbcl #'sb-impl::eql-hash
             #+ccl #'ccl::%%eqlhash)
            ((eq test #'equal)
             #+sbcl #'sb-impl::equal-hash
             #-sbcl #'sxhash)
            ((eq test #'equalp)
             #+sbcl #'sb-impl::equalp-hash
             #+ccl #'ccl::%%equalphash
             ;; FIXME: implement own equalp hash
             )
            (T
             #+sbcl (third (find test sb-impl::*user-hash-table-tests* :key #'second))))
      (error "Don't know a hasher for ~a." test)))

(defvar *maximum-size* (* 8 1024 1024))
(defun make-castable (&key test size hash-function)
  (let* ((size (min *maximum-size* (max MIN-SIZE (or size 0))))
         (test (etypecase test
                 (null #'eql)
                 (function test)
                 (symbol (fdefinition test))))
         (hash-function (etypecase hash-function
                          (null (determine-hasher test))
                          (function hash-function)
                          (symbol (fdefinition hash-function)))))
    (let ((power-of-two (expt 2 (integer-length size))))
      (let ((kvs (make-array (+ 2 (ash power-of-two 1)) :initial-element NO-VALUE)))
        (setf (svref kvs 0) (make-chm (make-counter)))
        (setf (svref kvs 1) (make-array power-of-two :element-type 'fixnum :initial-element 0))
        (%make-castable kvs (get-internal-real-time) test hash-function)))))

(declaim (inline hash))
(defun hash (table thing)
  (rehash (funcall (%castable-hasher table) thing)))

;; Not `int size()` from the original! This is more like HASH-TABLE-SIZE, as
;; it is the number of mappings that can be held right now.
(defun size (table)
  (/ (- (length (%castable-kvs table)) 2) 2))

;; L281 int size()
(defun count (table)
  (chm-size (chm (%castable-kvs table))))

(defun test (table)
  (%castable-test table))

(defun hash-function (table)
  (%castable-hasher table))

;; L321 TypeV putIfAbsent(TypeK, TypeV)
(defun put-if-absent (table key value)
  (multiple-value-bind (out present?)
      (put-if-match table key value TOMBSTONE)
    (declare (ignore out))
    (not present?)))
;; Missing: containsValue
;; L342 boolean replace(TypeK, TypeV)
(defun put-if-present (table key value)
  (multiple-value-bind (out present?)
      (put-if-match table key value MATCH-ANY)
    (if present?
        (funcall (%castable-test table) out value)
        nil)))
;; L347 boolean replace(TypeK, TypeV, TypeV)
(defun put-if-equal (table key new-value old-value)
  (multiple-value-bind (out present?)
      (put-if-match table key new-value old-value)
    (if present?
        (funcall (%castable-test table) old-value out)
        nil)))
;; Missing: clone

;; L313 put(TypeK, TypeV)
(defun (setf gethash) (value key table &optional default)
  (declare (ignore default))
  (put-if-match table key value NO-MATCH-OLD)
  value)

;; Close to L329 TypeV remove(Object)
;; REMHASH returns true if there was a mapping and false otherwise, but
;; remove() returns `null` or the old value.
(defun remhash (key table)
  (if (eq TOMBSTONE (%put-if-match table (%castable-kvs table) key TOMBSTONE NO-MATCH-OLD))
      NIL
      T))

;; Close to L334 boolean remove(Object, Object)
(defun try-remhash (table key val)
  (multiple-value-bind (out present?)
      (put-if-match table key TOMBSTONE val)
    (if present?
        (funcall (%castable-test table) out val)
        nil)))
;; L352 TypeV putIfMatch(Object, Object, Object)
(defun put-if-match (table key new old)
  (let ((res (%put-if-match table (%castable-kvs table) key new old)))
    (assert (not (prime-p res)))
    (assert (not (eq res NO-VALUE)))
    (if (eq res TOMBSTONE)
        (values NIL NIL)
        (values res T))))
;; L372 void clear()
(defun clrhash (table)
  (let ((new (%castable-kvs (make-castable))))
    (loop until (cas (%castable-kvs table) (%castable-kvs table) new))))

(declaim (inline keyeq))
;; L467 boolean keyeq(Object, Object, int[], int, int)
(defun keyeq (k key hashes hash fullhash test)
  (declare (type fixnum hash fullhash)
           (type (function (T T) boolean) test)
           (type (simple-array fixnum (*)) hashes)
           (optimize (speed 3) (debug 0) (safety 0)))
  (or (eq k key)
      ;; Key does not match exactly, so try more expensive comparison.
      (and ;; If the hash exists, does it match?
           (or (= (aref hashes hash) 0)
               (= (aref hashes hash) fullhash))
           ;; Avoid testing tombstones
           (not (eq k TOMBSTONE))
           ;; Call test function for real comparison
           (funcall test key k))))
;; L502 Object get_impl(NonBlockingHashMap, Object[], Object, int)
(defun %gethash (table kvs key fullhash)
  (declare (type castable table)
           (type simple-vector kvs)
           (type fixnum fullhash)
           (optimize (speed 3)))
  (let* ((len (len kvs))
         (chm (chm kvs))
         (hashes (hashes kvs))
         (idx (logand fullhash (1- len)))
         (test (%castable-test table))
         (reprobe-count 0))
    (declare (fixnum reprobe-count))
    ;; Spin for a hit
    (loop (let ((k (key kvs idx))
                (v (val kvs idx)))
            ;; Early table miss
            (when (eq k NO-VALUE) (return NO-VALUE))
            (let ((newkvs (%chm-newkvs chm)))
              ;; Compare the keys
              (when (keyeq k key hashes idx fullhash test)
                ;; If we are not copying at the moment, we're done.
                (unless (prime-p v)
                  (return (if (eq v TOMBSTONE)
                              NO-VALUE
                              v)))
                ;; Copy in progress, help with copying and retry.
                (return (%gethash table
                                   (copy-slot-and-check chm table kvs idx key)
                                   key
                                   fullhash)))
              ;; If we exceed reprobes, help resizing.
              (when (<= (reprobe-limit len) (incf reprobe-count))
                (if (null newkvs)
                    ;; Nothing here.
                    (return NO-VALUE)
                    ;; Retry in a new table copy
                    (return (%gethash table (help-copy table newkvs) key fullhash))))
              ;; Reprobe.
              (setf idx (logand (1+ idx) (1- len))))))))

;; L495 TypeV get(Object)
(defun gethash (key table &optional default)
  (declare (optimize speed))
  (let* ((fullhash (hash table key))
         (value (%gethash table (%castable-kvs table) key fullhash)))
    ;; Make sure we never return primes
    (assert (not (prime-p value)))
    (if (eql value NO-VALUE)
        (values default NIL)
        (values value T))))

;; L555 Object putIfMatch(NonBlockingHashMap, Object[], Object, Object, Object)
(defun %put-if-match (table kvs key put exp)
  (declare (type castable table))
  (declare (type simple-vector kvs))
  (declare (optimize speed))
  (assert (and (not (prime-p put))
               (not (prime-p exp))))
  (let* ((len (len kvs))
         (chm (chm kvs))
         (hashes (hashes kvs))
         (fullhash (hash table key))
         (test (%castable-test table))
         (idx (logand fullhash (1- len)))
         (reprobe-count 0)
         (k NO-VALUE) (v NO-VALUE)
         (newkvs NIL))
    (declare (type fixnum idx reprobe-count)
             (type chm chm))
    ;; Spin for a hit
    (loop (setf v (val kvs idx))
          (setf k (key kvs idx))
          ;; Is the slot free?
          (when (eq k NO-VALUE)
            ;; No need to put a tombstone in an empty field
            (when (eq put TOMBSTONE)
              (return-from %put-if-match put))
            ;; Claim the spot
            (when (cas-key kvs idx NO-VALUE key)
              (incf-counter (%chm-slots chm))
              (setf (aref hashes idx) fullhash)
              (return))
            ;; We failed, update the key
            (setf k (key kvs idx))
            (assert (not (eq k NO-VALUE))))
          ;; Okey, we have a key there
          (setf newkvs (%chm-newkvs chm))
          ;; Test if this is our key
          (when (keyeq k key hashes idx fullhash test)
            (return))
          ;; If we exceed reprobes, start resizing
          (when (>= (incf reprobe-count) (reprobe-limit len))
            (setf newkvs (resize chm table kvs))
            (unless (eq exp NO-VALUE) (help-copy table newkvs))
            (return-from %put-if-match
              (%put-if-match table newkvs key put exp)))
          ;; Reprobe.
          (setf idx (logand (1+ idx) (1- len))))
    ;; We found a key slot, time to update it
    ;; Fast-path
    (when (eq put v) (return-from %put-if-match v))
    ;; Check if we want to move to a new table
    (when (and ;; Do we have a new table already?
               (null newkvs)
               ;; Check the value
               (or (and (eq v NO-VALUE) (table-full-p chm reprobe-count len))
                   (prime-p v)))
      (setf newkvs (resize chm table kvs)))
    ;; Check if we are indeed moving and retry
    (unless (null newkvs)
      (return-from %put-if-match
        (%put-if-match table (copy-slot-and-check chm table kvs idx exp) key put exp)))
    ;; Finally we can do the update
    (loop (assert (not (prime-p v)))
          ;; If we don't match the old, bail out
          (when (and (not (eq exp NO-MATCH-OLD))
                     (not (eq v exp))
                     (or (not (eq exp MATCH-ANY))
                         (eq v TOMBSTONE)
                         (eq v NO-VALUE))
                     (not (and (eq v NO-VALUE) (eq exp TOMBSTONE)))
                     ;; FIXME: Should we use the same test for key & value?
                     (or (eq exp NO-VALUE) (not (eq exp v))))
            (return v))
          ;; Perform the change
          (when (cas-val kvs idx v put)
            ;; Okey, we got it, update the size
            (unless (eq exp NO-VALUE)
              (when (and (or (eq v NO-VALUE) (eq v TOMBSTONE))
                         (not (eq put TOMBSTONE)))
                (incf-counter (%chm-size chm)))
              (when (and (not (or (eq v NO-VALUE) (eq v TOMBSTONE)))
                         (eq put TOMBSTONE))
                (decf-counter (%chm-size chm))))
            (return (if (and (eq v NO-VALUE) (not (eq exp NO-VALUE)))
                        TOMBSTONE
                        v)))
          ;; CAS failed, retry
          (setf v (val kvs idx))
          ;; If we got a prime we need to restart from the beginning
          (when (prime-p v)
            (return (%put-if-match table (copy-slot-and-check chm table kvs idx exp) key put exp))))))

;; L699 Object[] help_copy(Object[])
(declaim (inline help-copy))
(defun help-copy (table helper)
  (declare (type castable table))
  (declare (optimize speed))
  (let* ((topkvs (%castable-kvs table))
         (topchm (chm topkvs)))
    (unless (null (%chm-newkvs topchm))
      (%help-copy topchm table topkvs NIL)))
    helper)

;; L794 Object[] resize(NonBlockingHashMap, Object[])
(defun resize (chm table kvs)
  (declare (type chm chm))
  (declare (type castable table))
  (declare (type simple-array kvs))
  (declare (optimize speed))
  (assert (eq chm (chm kvs)))
  ;; Check for resize in progress
  (let ((newkvs (%chm-newkvs chm)))
    (unless (null newkvs)
      ;; Use the new table already
      (return-from resize newkvs))
    (let* ((oldlen (len kvs))
           (sz (chm-size chm))
           (newsz sz))
      (declare (type fixnum oldlen sz newsz))
      ;; Heuristic for new size
      (when (<= (ash oldlen -2) sz)
        (setf newsz (ash oldlen 1))
        #+cliff-heuristics
        (when (<= sz (ash oldlen -1))
          (setf newsz (ash oldlen 2))))
      ;; Much denser table with more reprobes
      (when (<= (ash oldlen -1) sz)
        (setf newsz (ash oldlen 1)))
      ;; Was the last resize recent? If so, double again
      ;; to accommodate tables with lots of inserts at the moment.
      #+cliff-heuristics
      (let ((tm (get-internal-real-time)))
        (when (and (<= newsz oldlen)
                   ;; If we resized less than a second ago
                   (<= tm (+ (%castable-last-resize table)
                             INTERNAL-TIME-UNITS-PER-SECOND))
                   ;; And we have plenty of dead keys
                   (<= (ash sz 1) (counter-value~ (%chm-slots chm))))
          (setf newsz (ash oldlen 1))))
      ;; Don't shrink
      (when (< newsz oldlen) (setf newsz oldlen))
      (let ((size MIN-SIZE)
            (r (%chm-resizers chm)))
        (declare (type fixnum size))
        ;; Convert to power of two
        (loop while (< size newsz)
              do (setf size (ash size 1)))
        ;; Limit the number of threads resizing things
        (loop until (cas (%chm-resizers chm) r (1+ r))
              do (setf r (%chm-resizers chm)))
        ;; Size calculation: 2 words per table + extra
        ;; NOTE: The original assumes 32 bit pointers, we conditionalise
        (let ((megs (ash (ash (+ (* size 2) 4)
                              #+64-BIT 4 #-64-BIT 3)
                         -20)))
          (declare (type fixnum megs))
          (when (and (<= 2 r) (< 0 megs))
            (setf newkvs (%chm-newkvs chm))
            (unless (null newkvs)
              (return-from resize newkvs))
            ;; We already have two threads trying a resize, wait
            (sleep (/ (* 8 megs) 1000))))
        ;; Last check
        (setf newkvs (%chm-newkvs chm))
        (unless (null newkvs)
          (return-from resize newkvs))
        ;; Allocate the array
        (setf newkvs (make-array (+ 2 (* 2 size)) :initial-element NO-VALUE))
        (setf (svref newkvs 0) (make-chm (%chm-size chm)))
        (setf (svref newkvs 1) (make-array size :element-type 'fixnum :initial-element 0))
        ;; Check again after the allocation
        (unless (null (%chm-newkvs chm))
          (return-from resize (%chm-newkvs chm)))
        ;; CAS the table in. We can let the GC handle deallocation. Thanks, GC!
        (if (cas-newkvs chm newkvs)
            newkvs
            (%chm-newkvs chm))))))

;; L906 help_copy_impl(NonBlockingHashMap, Object[], boolean)
(defun %help-copy (chm table oldkvs copy-all)
  (declare (type chm chm))
  (declare (type castable table))
  (declare (type simple-array oldkvs))
  (declare (optimize speed))
  (assert (eq chm (chm oldkvs)))
  (let* ((newkvs (%chm-newkvs chm))
         (oldlen (len oldkvs))
         (min-copy-work (min oldlen 16384))
         (panic-start -1)
         (copy-idx 0)
         #+report-resize
         (start-time (get-internal-real-time)))
    (declare (type fixnum oldlen min-copy-work panic-start)
             ((and unsigned-byte fixnum) copy-idx))
    (assert (not (null newkvs)))
    ;; Loop while there's work to be done
    (loop while (< (%chm-copy-done chm) oldlen)
          do ;; We panic if we tried to copy twice and it failed.
          (when (= -1 panic-start)
            (setf copy-idx (%chm-copy-idx chm))
            (loop while (and (< copy-idx (ash oldlen 1))
                             (not (cas (%chm-copy-idx chm) copy-idx (+ copy-idx min-copy-work))))
                  do (setf copy-idx (%chm-copy-idx chm)))
            (unless (< copy-idx (ash oldlen 1))
              (setf panic-start copy-idx)))
          ;; Okey, now perform the copy.
          (let ((workdone 0))
            (declare (type fixnum workdone))
            (dotimes (i min-copy-work)
              (when (copy-slot table (logand (+ copy-idx i) (1- oldlen))
                               oldkvs newkvs)
                (incf workdone)))
            ;; Promote our work
            (when (plusp workdone)
              (copy-check-and-promote chm table oldkvs workdone))
            (incf copy-idx min-copy-work)
            ;; End early if we shouldn't copy everything.
            (when (and (not copy-all) (= -1 panic-start))
              (return-from %help-copy))))
    ;; Promote again in case we race on end of copy
    (copy-check-and-promote chm table oldkvs 0)
    #+report-resize
    (format t "~&took ~$ seconds copying"
            (/ (- (get-internal-real-time) start-time)
               internal-time-units-per-second))))

;; Copy the slot and check that we have done so successfully.
;; L970 Object[] copy_slot_and_check(NonBlockingHashMap, Object[], int, Object)
(defun copy-slot-and-check (chm table oldkvs idx should-help)
  (declare (type chm chm))
  (declare (type castable table))
  (declare (type simple-array oldkvs))
  (declare (optimize speed))
  (assert (eq chm (chm oldkvs)))
  (let ((newkvs (%chm-newkvs chm)))
    (assert (not (null newkvs)))
    (when (copy-slot table idx oldkvs (%chm-newkvs chm))
      (copy-check-and-promote chm table oldkvs 1))
    (if should-help
        (help-copy table newkvs)
        newkvs)))

;; L983 copy_check_and_promote(NonBlockingHashMap, Object[], int)
(defun copy-check-and-promote (chm table oldkvs work-done)
  (declare (type chm chm))
  (declare (type castable table))
  (declare (type simple-vector oldkvs))
  (declare (type fixnum work-done))
  (declare (optimize speed))
  (assert (eq chm (chm oldkvs)))
  (let ((oldlen (len oldkvs))
        (copy-done (%chm-copy-done chm)))
    (assert (<= (+ copy-done work-done) oldlen))
    (when (plusp work-done)
      (loop until (cas (%chm-copy-done chm) copy-done (+ copy-done work-done))
            do (setf copy-done (%chm-copy-done chm))
               (assert (<= (+ copy-done work-done) oldlen)))
      #+report-resize
      (when (/= (floor (* 10 copy-done) oldlen)
                (floor (* 10 (+ copy-done work-done)) oldlen))
        (format t "~&copied ~3d%"
                (floor (* 100 copy-done) oldlen))))
    ;; Check for copy being completely done and promote
    (when (and (= (+ copy-done work-done) oldlen)
               (eq (%castable-kvs table) oldkvs)
               (cas (%castable-kvs table) oldkvs (%chm-newkvs chm)))
      (setf (%castable-last-resize table) (get-internal-real-time)))))

;; Copy one slot into the new table,
;; returns true if we are sure that the new table has a value.
;; L1023 boolean copy_slot(NonBlockingHashMap, int, Object[], Object[])
(declaim (inline copy-slot))
(defun copy-slot (table idx oldkvs newkvs)
  (declare (type castable table))
  (declare (type fixnum idx))
  (declare (type simple-vector oldkvs newkvs))
  (declare (optimize speed))
  ;; First tombstone the key blindly.
  (let (key)
    (loop while (eq (setf key (key oldkvs idx)) NO-VALUE)
          do (cas-key oldkvs idx NO-VALUE TOMBSTONE))
    ;; Prevent new values from showing up in the old table
    (let ((oldval (val oldkvs idx)))
      (loop until (prime-p oldval)
            for box = (if (or (eq oldval NO-VALUE)
                              (eq oldval TOMBSTONE))
                          TOMBPRIME
                          (prime oldval))
            do (when (cas-val oldkvs idx oldval box)
                 ;; We made sure to prime the value to prevent updates.
                 (when (eq box TOMBPRIME)
                   (return-from copy-slot T))
                 (setf oldval box)
                 (return))
               ;; Retry on CAS failure
               (setf oldval (val oldkvs idx)))
      (when (eq oldval TOMBPRIME)
        ;; We already completed the copy
        (return-from copy-slot NIL))
      ;; Finally do the actual copy, but only if we would write into
      ;; a null. Otherwise, someone else already copied.
      (let ((old-unboxed (prime-value oldval)))
        (assert (not (eq old-unboxed TOMBSTONE)))
        (prog1 (eq NO-VALUE (%put-if-match table newkvs key old-unboxed NO-VALUE))
          ;; Now that the copy is done, we can stub out the old key completely.
          (loop until (cas-val oldkvs idx oldval TOMBPRIME)
                do (setf oldval (val oldkvs idx))))))))

(defun maphash (function table)
  (let (snapshot-kvs)
    (loop for top-kvs = (%castable-kvs table)
          for top-chm = (chm top-kvs)
          for newkvs  = (%chm-newkvs top-chm)
          until (null newkvs)
          do (help-copy table newkvs)
          finally (setf snapshot-kvs top-kvs))
    (loop for position from 2 below (length snapshot-kvs) by 2
          for key   = (aref snapshot-kvs position)
          for value = (aref snapshot-kvs (1+ position))
          unless (or (eq key   NO-VALUE)
                     (eq key   TOMBSTONE)
                     (eq value NO-VALUE))
            do (funcall function key value))))

(defmethod print-object ((table castable) stream)
  (print-unreadable-object (table stream :type t :identity t)
    (format stream ":test ~s :count ~s :size ~s"
            (test table)
            (count table)
            (size table))))
