(in-package #:avm2-compiler)

;;; higher level functions from conses dictionary
;;; (mainly things that need iteration constructs)
;;;
;;; not all match CL semantics very closely yet...

(let ((*symbol-table* *cl-symbol-table*))

  ;; Function SUBLIS, NSUBLIS

  ;; Function SUBST, SUBST-IF, SUBST-IF-NOT, NSUBST, NSUBST-IF, NSUBST-IF-NOT

  ;; Function TREE-EQUAL

  ;; fixme: write iterative version of copy-list
  (swf-defun copy-list (list)
    (%flet (do-copy (list)
             (if (consp list)
                 (cons (car list) (do-copy (cdr list)))
                 list))
      (if (not (listp list))
          (%type-error "COPY-LIST" list)
          (call-%flet do-copy list))))

  ;; LIST, LIST* implemented as a special form for now due to lack of &rest

  (swf-defun list-length (list)
    (let ((fast list)
          (length 0))
      (dolist (slow list)
        (when (endp fast) (return  length))
        (when (endp (cdr fast)) (return  (+ length 1)))
        (when (and (eq fast slow) (> length 0)) (return nil))
        (setf fast (cddr fast)))))

  ;; LISTP in cl-conses

  ;; Function MAKE-LIST

  ;; PUSH, POP in cl-conses

  ;; FIRST - TENTH in cl-conses

  (swf-defmemfun nth (n list)
    (car (dotimes (x n list)
           (setf list (cdr list)))))

  ;; ENDP, NULL in cl-conses
  (swf-defmemfun nconc (&arest lists)
    (let* ((a (if (zerop (:length lists))
                 nil
                 (aref lists 0)))
          (end (last a)))
      (dotimes (i (1- (:length lists)) a)
        (let ((next (aref lists (1+ i))))
          (rplacd (last end) next)
          (setf end next)))))

  ;;Function APPEND

  ;;Function REVAPPEND, NRECONC

  ;;Function BUTLAST, NBUTLAST

  ;; fixme: add optional count arg
  (swf-defmemfun last (a)
      (if (endp a)
          nil
          (tagbody
           :start
             (unless (consp (cdr a))
               (return-from last a))
             (setf a (cdr a))
             (go :start))))

  ;;Function LDIFF, TAILP

  ;;Function NTHCDR
  (swf-defmemfun nthcdr (n list)
    (dotimes (a n list)
      (setf list (cdr list))))

  (swf-defmemfun rest (a)
    (cdr a))

  ;;Function MEMBER, MEMBER-IF, MEMBER-IF-NOT

  ;;Function MAPC, MAPCAR, MAPCAN, MAPL, MAPLIST, MAPCON

  ;;Function ACONS

  ;;Function ASSOC, ASSOC-IF, ASSOC-IF-NOT

  ;;Function COPY-ALIST

  ;;Function PAIRLIS

  ;;Function RASSOC, RASSOC-IF, RASSOC-IF-NOT

  ;;Function GET-PROPERTIES

  ;;Accessor GETF

  ;;Macro REMF

  ;;Function INTERSECTION, NINTERSECTION

  ;;Function ADJOIN

  ;;Macro PUSHNEW

  ;;Function SET-DIFFERENCE, NSET-DIFFERENCE

  ;;Function SET-EXCLUSIVE-OR, NSET-EXCLUSIVE-OR

  ;;Function SUBSETP

  ;;Function UNION, NUNION
)
