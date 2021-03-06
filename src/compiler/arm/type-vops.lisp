;;;; type testing and checking VOPs for the ARM VM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!VM")

(defun %test-fixnum (value target not-p &key temp)
  (declare (ignore temp))
  (assemble ()
    (inst tst value fixnum-tag-mask)
    (inst b (if not-p :ne :eq) target)))

(defun %test-fixnum-and-headers (value target not-p headers &key temp)
  (let ((drop-through (gen-label)))
    (assemble ()
      (inst ands temp value fixnum-tag-mask)
      (inst b :eq (if not-p drop-through target)))
    (%test-headers value target not-p nil headers
                   :drop-through drop-through :temp temp)))

(defun %test-immediate (value target not-p immediate &key temp)
  (assemble ()
    (inst and temp value widetag-mask)
    (inst cmp temp immediate)
    (inst b (if not-p :ne :eq) target)))

(defun %test-lowtag (value target not-p lowtag &key temp)
  (assemble ()
    (inst and temp value lowtag-mask)
    (inst cmp temp lowtag)
    (inst b (if not-p :ne :eq) target)))

(defun %test-headers (value target not-p function-p headers
                      &key temp (drop-through (gen-label)))
    (let ((lowtag (if function-p fun-pointer-lowtag other-pointer-lowtag)))
    (multiple-value-bind (when-true when-false)
        (if not-p
            (values drop-through target)
            (values target drop-through))
      (assemble ()
        (%test-lowtag value when-false t lowtag :temp temp)
        (load-type temp value (- lowtag))
        (do ((remaining headers (cdr remaining)))
            ((null remaining))
          (let ((header (car remaining))
                (last (null (cdr remaining))))
            (cond
              ((atom header)
               (cond
                 ((and (not last) (null (cddr remaining))
                       (atom (cadr remaining))
                       (= (logcount (logxor header (cadr remaining))) 1))
                  (inst and temp temp (ldb (byte 8 0) (logeqv header (cadr remaining))))
                  (inst cmp temp (ldb (byte 8 0) (logand header (cadr remaining))))
                  (inst b (if not-p :ne :eq) target)
                  (return))
                 (t
                  (inst cmp temp header)
                  (if last
                      (inst b (if not-p :ne :eq) target)
                      (inst b :eq when-true)))))
              (t
               (let ((start (car header))
                     (end (cdr header)))
                 (cond
                   ((and last (not (= start bignum-widetag))
                         (= (+ start 4) end)
                         (= (logcount (logxor start end)) 1))
                    (inst and temp temp (ldb (byte 8 0) (logeqv start end)))
                    (inst cmp temp (ldb (byte 8 0) (logand start end)))
                    (inst b (if not-p :ne :eq) target))
                   ((and (not last) (null (cddr remaining))
                         (= (+ start 4) end) (= (logcount (logxor start end)) 1)
                         (listp (cadr remaining))
                         (= (+ (caadr remaining) 4) (cdadr remaining))
                         (= (logcount (logxor (caadr remaining) (cdadr remaining))) 1)
                         (= (logcount (logxor (caadr remaining) start)) 1))
                    (inst and temp temp (ldb (byte 8 0) (logeqv start (cdadr remaining))))
                    (inst cmp temp (ldb (byte 8 0) (logand start (cdadr remaining))))
                    (inst b (if not-p :ne :eq) target)
                    (return))
                   (t
                    (unless (= start bignum-widetag)
                      (inst cmp temp start)
                      (if (= end complex-array-widetag)
                          (progn
                            (aver last)
                            (inst b (if not-p :lt :ge) target))
                          (inst b :lt when-false)))
                    (unless (= end complex-array-widetag)
                      (inst cmp temp end)
                      (if last
                          (inst b (if not-p :gt :le) target)
                          (inst b :le when-true))))))))))
        (emit-label drop-through)))))

;;; Type checking and testing (see also the use of !DEFINE-TYPE-VOPS
;;; in src/compiler/generic/late-type-vops.lisp):
;;;
;;; [FIXME: Like some of the other comments in this file, this one
;;; really belongs somewhere else]
(define-vop (check-type)
  (:args (value :target result :scs (any-reg descriptor-reg)))
  (:results (result :scs (any-reg descriptor-reg)))
  (:temporary (:scs (non-descriptor-reg)
                    :to (:result 0)
                    :offset ocfp-offset)
              temp)
  (:vop-var vop)
  (:save-p :compute-only))

(define-vop (type-predicate)
  (:args (value :scs (any-reg descriptor-reg)))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe))

(defun cost-to-test-types (type-codes)
  (+ (* 2 (length type-codes))
     (if (> (apply #'max type-codes) lowtag-limit) 7 2)))

(defmacro !define-type-vops (pred-name check-name ptype error-code
                             (&rest type-codes)
                             &key &allow-other-keys)
  (let ((cost (cost-to-test-types (mapcar #'eval type-codes))))
    `(progn
       ,@(when pred-name
           `((define-vop (,pred-name type-predicate)
               (:translate ,pred-name)
               (:generator ,cost
                 (test-type value target not-p (,@type-codes)
                            :temp temp)))))
       ,@(when check-name
           `((define-vop (,check-name check-type)
               (:generator ,cost
                 (let ((err-lab
                        (generate-error-code vop ',error-code value)))
                   (test-type value err-lab t (,@type-codes)
                              :temp temp)
                   (move result value))))))
       ,@(when ptype
           `((primitive-type-vop ,check-name (:check) ,ptype))))))

;;;; Other integer ranges.

;;; A (signed-byte 32) can be represented with either fixnum or a bignum with
;;; exactly one digit.
(defun signed-byte-32-test (value temp not-p target not-target)
  (multiple-value-bind
        (yep nope)
      (if not-p
          (values not-target target)
          (values target not-target))
    (assemble ()
      (inst ands temp value fixnum-tag-mask)
      (inst b :eq yep)
      (test-type value nope t (other-pointer-lowtag) :temp temp)
      (loadw temp value 0 other-pointer-lowtag)
      ;; (+ (ash 1 n-widetag-bits) bignum-widetag) does not fit into a single immediate
      (inst eor temp temp (ash 1 n-widetag-bits))
      (inst eors temp temp bignum-widetag)
      (inst b (if not-p :ne :eq) target)))
  (values))

(define-vop (signed-byte-32-p type-predicate)
  (:translate signed-byte-32-p)
  (:generator 45
   (let ((not-target (gen-label)))
     (signed-byte-32-test value temp not-p target not-target)
     (emit-label not-target))))

(define-vop (check-signed-byte-32 check-type)
  (:generator 45
    (let ((nope (generate-error-code vop 'object-not-signed-byte-32-error value))
          (yep (gen-label)))
      (signed-byte-32-test value temp t nope yep)
      (emit-label yep)
      (move result value))))

;;; An (UNSIGNED-BYTE 32) can be represented with either a positive
;;; fixnum, a bignum with exactly one positive digit, or a bignum with
;;; exactly two digits and the second digit all zeros.
(defun unsigned-byte-32-test (value temp not-p target not-target)
  (let ((single-word (gen-label))
        (fixnum (gen-label)))
    (multiple-value-bind (yep nope)
        (if not-p
            (values not-target target)
            (values target not-target))
      (assemble ()
        ;; Is it a fixnum?
        (move temp value)
        (%test-fixnum temp fixnum nil)

        ;; If not, is it an other pointer?
        (test-type value nope t (other-pointer-lowtag) :temp temp)
        ;; Get the header.
        (loadw temp value 0 other-pointer-lowtag)
        ;; Is it one?
        ;; (+ (ash 1 n-widetag-bits) bignum-widetag) does not fit into a single immediate
        (inst eor temp temp (ash 1 n-widetag-bits))
        (inst eors temp temp bignum-widetag)
        (inst b :eq single-word)
        ;; If it's other than two, we can't be an (unsigned-byte 32)
        (inst eors temp temp (logxor (+ (ash 1 n-widetag-bits) bignum-widetag)
                                     (+ (ash 2 n-widetag-bits) bignum-widetag)))
        (inst b :ne nope)
        ;; Get the second digit.
        (loadw temp value (1+ bignum-digits-offset) other-pointer-lowtag)
        ;; All zeros, its an (unsigned-byte 32).
        (inst cmp temp 0)
        (inst b :eq yep)
        (inst b nope)

        (emit-label single-word)
        ;; Get the single digit.
        (loadw temp value bignum-digits-offset other-pointer-lowtag)

        ;; positive implies (unsigned-byte 32).
        (emit-label fixnum)
        (inst cmp temp 0)
        (if not-p
            (inst b :lt target)
            (inst b :ge target))))
    (values)))

(define-vop (unsigned-byte-32-p type-predicate)
  (:translate unsigned-byte-32-p)
  (:generator 45
   (let ((not-target (gen-label)))
     (unsigned-byte-32-test value temp not-p target not-target)
     (emit-label not-target))))

(define-vop (check-unsigned-byte-32 check-type)
  (:generator 45
    (let ((lose (generate-error-code vop 'object-not-unsigned-byte-32-error value))
          (okay (gen-label)))
      (unsigned-byte-32-test value temp t lose okay)
      (emit-label okay)
      (move result value))))

;;; MOD type checks
(defun power-of-two-limit-p (x)
  (and (fixnump x)
       (= (logcount (1+ x)) 1)
       ;; Immediate encodable
       (> x (expt 2 23))))

(define-vop (test-fixnum-mod-power-of-two)
  (:args (value :scs (any-reg descriptor-reg
                              unsigned-reg signed-reg
                              immediate)))
  (:arg-types *
              (:constant (satisfies power-of-two-limit-p)))
  (:translate fixnum-mod-p)
  (:conditional :eq)
  (:info hi)
  (:save-p :compute-only)
  (:policy :fast-safe)
  (:generator 2
     (aver (not (sc-is value immediate)))
     (let* ((fixnum-hi (if (sc-is value unsigned-reg signed-reg)
                           hi
                           (fixnumize hi))))
       (inst tst value (lognot fixnum-hi)))))

(define-vop (test-fixnum-mod-tagged-unsigned-imm)
  (:args (value :scs (any-reg descriptor-reg
                              unsigned-reg signed-reg
                              immediate)))
  (:arg-types (:or tagged-num unsigned-num signed-num)
              (:constant (satisfies encodable-immediate)))
  (:translate fixnum-mod-p)
  (:conditional :ls)
  (:info hi)
  (:save-p :compute-only)
  (:policy :fast-safe)
  (:generator 3
     (aver (not (sc-is value immediate)))
     (let ((fixnum-hi (if (sc-is value unsigned-reg signed-reg)
                          hi
                          (fixnumize hi))))
       (inst cmp value fixnum-hi))))

(defun encodable-immediate+1 (x)
  (encodable-immediate (1+ x)))

;;; Adding 1 and changing the codntions from <= to < allows to encode
;;; more immediates.
(define-vop (test-fixnum-mod-tagged-unsigned-imm+1)
  (:args (value :scs (any-reg descriptor-reg
                              unsigned-reg signed-reg
                              immediate)))
  (:arg-types (:or tagged-num unsigned-num signed-num)
              (:constant (satisfies encodable-immediate+1)))
  (:translate fixnum-mod-p)
  (:conditional :cc)
  (:info hi)
  (:save-p :compute-only)
  (:policy :fast-safe)
  (:generator 3
     (aver (not (sc-is value immediate)))
     (let ((fixnum-hi (if (sc-is value unsigned-reg signed-reg)
                          (1+ hi)
                          (fixnumize (1+ hi)))))
       (inst cmp value fixnum-hi))))

(define-vop (test-fixnum-mod-tagged-unsigned)
  (:args (value :scs (any-reg descriptor-reg
                              unsigned-reg signed-reg
                              immediate)))
  (:arg-types (:or tagged-num unsigned-num signed-num)
              (:constant fixnum))
  (:temporary (:scs (non-descriptor-reg)) temp)
  (:translate fixnum-mod-p)
  (:conditional :ls)
  (:info hi)
  (:save-p :compute-only)
  (:policy :fast-safe)
  (:generator 4
     (aver (not (sc-is value immediate)))
     (let ((fixnum-hi (if (sc-is value unsigned-reg signed-reg)
                          hi
                          (fixnumize hi))))
       (load-immediate-word temp fixnum-hi)
       (inst cmp value temp))))

(defun encodable-immediate/+1 (x)
  (or (encodable-immediate x)
      (encodable-immediate (1+ x))))

(define-vop (test-fixnum-mod-*-imm)
  (:args (value :scs (any-reg descriptor-reg)))
  (:arg-types * (:constant (satisfies encodable-immediate/+1)))
  (:translate fixnum-mod-p)
  (:conditional)
  (:info target not-p hi)
  (:save-p :compute-only)
  (:policy :fast-safe)
  (:generator 5
    (let* ((1+ (not (encodable-immediate hi)))
           (fixnum-hi (fixnumize (if 1+
                                     (1+ hi)
                                     hi)))
           (skip (gen-label)))
      (inst tst value fixnum-tag-mask)
      (inst b :ne (if not-p target skip))
      (inst cmp value fixnum-hi)
      (inst b (if not-p
                  (if 1+ :cs :hi)
                  (if 1+ :cc :ls))
            target)
      (emit-label SKIP))))

(define-vop (test-fixnum-mod-*)
  (:args (value :scs (any-reg descriptor-reg)))
  (:arg-types * (:constant fixnum))
  (:translate fixnum-mod-p)
  (:temporary (:scs (any-reg)) temp)
  (:conditional)
  (:info target not-p hi)
  (:save-p :compute-only)
  (:policy :fast-safe)
  (:generator 6
    (inst tst value fixnum-tag-mask)
    (inst b :ne (if not-p target skip))
    (let ((condition (if not-p :hi :ls)))
      (load-immediate-word temp (fixnumize hi))
      (inst cmp value temp)
      (inst b condition target))
    SKIP))

;;;; List/symbol types:
;;;
;;; symbolp (or symbol (eq nil))
;;; consp (and list (not (eq nil)))

(define-vop (symbolp type-predicate)
  (:translate symbolp)
  (:generator 12
    (let* ((drop-thru (gen-label))
           (is-symbol-label (if not-p drop-thru target)))
      (inst cmp value null-tn)
      (inst b :eq is-symbol-label)
      (test-type value target not-p (symbol-header-widetag) :temp temp)
      (emit-label drop-thru))))

(define-vop (check-symbol check-type)
  (:generator 12
    (let ((drop-thru (gen-label))
          (error (generate-error-code vop 'object-not-symbol-error value)))
      (inst cmp value null-tn)
      (inst b :eq drop-thru)
      (test-type value error t (symbol-header-widetag) :temp temp)
      (emit-label drop-thru)
      (move result value))))

(define-vop (consp type-predicate)
  (:translate consp)
  (:generator 8
    (let* ((drop-thru (gen-label))
           (is-not-cons-label (if not-p target drop-thru)))
      (inst cmp value null-tn)
      (inst b :eq is-not-cons-label)
      (test-type value target not-p (list-pointer-lowtag) :temp temp)
      (emit-label drop-thru))))

(define-vop (check-cons check-type)
  (:generator 8
    (let ((error (generate-error-code vop 'object-not-cons-error value)))
      (inst cmp value null-tn)
      (inst b :eq error)
      (test-type value error t (list-pointer-lowtag) :temp temp)
      (move result value))))
