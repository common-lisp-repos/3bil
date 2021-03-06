(in-package :avm2-compiler)

;;; trivial ir2: asm
;;;


;;; collect some info that doesn't really fit in the ir1 stuff since
;;;   it probably wouldn't apply to a smarter ir2 (probably some of the
;;;   current ir1 belongs here too...)
;;; mark vars that need a slot in activation records
;;; assign indices for nlx go tags
(defparameter *current-closure-index* nil)
(defparameter *current-closure-vars* nil)
;; fixme: pick a better name for this now that it does something else too
(define-structured-walker mark-activations null-ir1-walker
  :form-var whole
  :labels ((set-tag-info (var flag value)
                         (setf (getf (getf *ir1-tag-info* var nil) flag) value))
           (get-tag-info (var flag &optional default)
                         (getf (getf *ir1-tag-info* var nil) flag default)))
  :forms
  (((%named-lambda name flags lambda-list closed-vars types activation-vars body)
    (let ((*ir1-in-tagbody* nil)
          (*current-closure-vars* nil)
          (*current-closure-index* 1))
      (when activation-vars (error "got activation-vars, expected nil?"))
      (loop for i in closed-vars
            do (push (list i (1- (incf *current-closure-index*)))
                     *current-closure-vars*))
      (let ((rbody (recur-all body)))
        `(%named-lambda
          name ,name
          flags ,flags
          lambda-list ,lambda-list
          closed-vars ,closed-vars
          types ,types
          activation-vars ,*current-closure-vars*
          body ,rbody))))
   ((%bind vars values closed-vars body)
    (loop for i in closed-vars
          do (push (list i (1- (incf *current-closure-index*)))
                   *current-closure-vars*))
    (super whole))
   ((tagbody name nlx forms)
    (when nlx
      (loop with j = 0
            for i in forms
            when (atom i)
            do (set-tag-info i :nlx-index (1- (incf j)))))
    (super whole))))


;;; mark function calls needing args in temps due to catch blocks
;;;  (possibly splitting args into before/after groups so latter set don't
;;;   need temporaries)
(defparameter *ir2-call-stack* nil)
(define-structured-walker ir2-mark-spilled-args null-ir1-walker
  :form-var whole
  :labels ((mark-catch-arg ()
             ;; loop over every call in progress, and mark current arg as
             ;; having an exception block
             (loop for i in *ir2-call-stack*
                   do (setf (caaadr i) t)))
           (set-var-info (var flag value)
             (setf (getf (getf *ir1-var-info* var nil) flag) value))
           (inc-var-info (var flag value &optional init)
             (incf (getf (getf *ir1-var-info* var nil) flag init) value))
           (spillable-arglist (args)
            (let* ((tag (gensym "tag"))
                   (flags (list nil))
                   (*ir2-call-stack* (cons (list tag flags) *ir2-call-stack*))
                   (recurred-args (loop for i in args
                                     ;; fixme: caadar is ugly, make
                                     ;; the structure/access more
                                     ;; obvious...
                                     do (push nil (caadar *ir2-call-stack*))
                                     collect (recur i))))
              ;; flags is reversed list of flag indicating
              ;; corresponding arg has a exception block, so we need
              ;; to spill it and any preceding args into locals
              ;; instead of leaving it on the stack, since exception
              ;; handler will clear stack...
              (loop for f in (nreverse (loop with spill = nil
                                          for f in (car flags)
                                          when f
                                          do (setf spill t)
                                          when spill collect t
                                          else collect nil))
                 for arg in recurred-args
                 for sym = (gensym "ARG-TEMP-")
                 when f
                 collect sym into spilled-vars
                 and collect arg into spilled-values
                 else collect arg into inline
                 finally (return (values spilled-vars
                                         spilled-values
                                         inline
                                         recurred-args))))))


  :forms (((%call type name args)
           (let* ((r-name (if (eq type :local) (recur name) name)))
             (multiple-value-bind (spilled-vars spilled-values inline
                                                recurred-args)
                 (spillable-arglist args)
               (if spilled-vars
                   ;; some args need to be in locals, so replace the
                   ;; call with a local binding to allocate temp vars,
                   ;; and a call with the locals as args instead of
                   ;; the original forms
                   `(%bind
                     vars ,spilled-vars
                     values ,spilled-values
                     closed-vars nil
                     types ,(mapcar (constantly t) spilled-vars)
                     body
                     ((%call
                       type ,type
                       name ,r-name
                       args ,(append
                              (loop
                                 for i in spilled-vars
                                 for v in spilled-values
                                 do (inc-var-info
                                     i :ref-count 1 0)
                                   (set-var-info i :type t )
                                   (set-var-info i :simple-init
                                                 (simple-quote-p v))
                                   (when (simple-quote-p v)
                                     (set-var-info i :simple-init-value v))
                                 collect
                                 `(%ref type :local
                                        var ,i))
                              inline))))
                   ;; normal case, just leave args inline (we already
                   ;; did the recur-all, so don't need it here...)
                   `(%call type ,type
                           name ,r-name
                           args ,recurred-args)))))


          ((%asm forms)
           ;; we need to handle the same issue for %asm, for example
           ;; when we inline math ops, or cons or whatever, so we have
           ;; a special pseudo-opcode for pushing a list of args on
           ;; the stack with automatic spilling/reloading around
           ;; exceptions
           `(%asm
             forms
             ,(loop for i in forms
                 for op = (first i)
                 when (eq (car i) :@)
                 collect `(:@ ,(recur (second i)) ,@(cddr i))
                 else when (eq (car i) :%exception)
                 do (mark-catch-arg)
                 and collect i
                 else when (eq op :%push-arglist)
                 append
                 (multiple-value-bind (spilled-vars spilled-values inline)
                     (spillable-arglist (loop for a in (cdr i)
                                           collect `(%asm forms (,a))))
                   (if spilled-vars
                       `((:@ (%bind vars ,spilled-vars
                                    values ,spilled-values
                                    closed-vars nil
                                    types ,(mapcar (constantly t) spilled-vars)
                                    body ((%asm
                                           forms
                                           ,(append
                                             (loop for i in spilled-vars
                                                collect
                                                `(:@ (%ref type :local
                                                           var ,i)))
                                             ;; we need to remove the
                                             ;; extra %asm from any
                                             ;; remaining args
                                             (mapcar 'caaddr
                                                     inline)))))))
                       ;; normal case, just inline the args directly
                       (cdr i)))
                 else collect i)))

          ((block name nlx forms)
           (when nlx (mark-catch-arg))
           (super whole))
          ((tagbody name nlx forms)
           (when nlx (mark-catch-arg))
           (super whole))
          ((catch tag forms)
           (mark-catch-arg)
           (super whole))

          ;; we match local jumps too, to catch stuff like (+ 1 (go 2) 3))
          ;;  we should probably limit it to forms that actually exit the
          ;;  arglist, but being conservative for now
          ;;  (ex: (+ 1 (block x (return-from x 2)) 3) is safe
          ;;; (we need to catch exits from an arglist so stack depth matches
          ;;;  might be better to just add some :pop before the jump instead?)
          ((return-from name value)
           (mark-catch-arg)
           (super whole))
          ((go tag)
           (mark-catch-arg)
           (super whole))

          ;; u-w-p possibly shouldn't be here, since if we don't
          ;; trigger the exception block on normal exits from the
          ;; block, then the stack is still valid, and when it does
          ;; get triggered, we are probably going to rethrow it
          ;; anyway, so the call won't be made either way...
          ;; (unless we catch it in an enclosing catch/block/tagbody,
          ;;  in which case we marked the arg anyway)
          ((unwind-protect protected cleanup)
           (mark-catch-arg)
           (super whole))

          ((%compilation-unit lambdas)
           (let* ((*ir2-call-stack* nil))
             (super whole)))))


;;; extracting function deps from generated code seems like a hassle
;;; (hard to distinguish method calls from functions on global object,
;;; etc.), so running a separate pass to collect a list of functions
;;; called from each function for use by tree shaker
;; (possibly classes created too, but probably want to pull that from asm
;;  if possible, since we don't have an object creation primitives yet
;;  -- for now, just adding a pseudo-op to mark class deps, and calling that
;;     by hand as needed)
(defvar *ir2-function-deps*)
(defvar *ir2-class-deps*)
;;; we add stuff during assembly, so doesn't really work as a separate pass...
#++
(define-structured-walker ir2-collect-function-deps null-ir1-walker
  :form-var whole
  :forms
  (((%named-lambda name flags lambda-list closed-vars types activation-vars body)
    (let ((*ir2-function-deps* (getf flags :function-deps))
          (*ir2-class-deps* (getf flags :class-deps)))
      (let ((rbody (recur-all body)))
        (setf (getf flags :function-deps) *ir2-function-deps*)
        (setf (getf flags :class-deps) *ir2-class-deps*)
        `(%named-lambda
          name ,name
          flags ,flags
          lambda-list ,lambda-list
          closed-vars ,closed-vars
          types ,types
          activation-vars ,activation-vars
          body ,rbody))))
   ((%call type name args)
    (ecase type
      (:normal
       ;; for now we only add a dependency for normal functions, and
       ;; assume methods/static methods will be pulled in by the class
       (let ((tmp (find-swf-function name *symbol-table*)))
         (when tmp (pushnew (car tmp) *ir2-function-deps* :test 'equal)))
       ;; (also add a dep for unknown calls, just in case...)
       (unless (or (find-swf-static-method name *symbol-table*)
                   (find-swf-static-method name *symbol-table*))
          (pushnew name *ir2-function-deps* :test 'equal)))
      (:local
       (format t "icfd- local call = ~s~%" whole)
       ;; for now local calls go through a local var, so they get
       ;; handled by FUNCTION
       nil)
      (:setf
       ;; known properties get inlined (fixme: is this still valid?)
       (unless (find-swf-property name)
         (pushnew (list :setf name) *ir2-function-deps* :test 'equal))))
    (super whole))
   ((function type name)
    (ecase type
      (:local (pushnew name *ir2-function-deps* :test 'equal))
      (:normal (let (tmp)
                 ;; fixme: share code with function calls?
                 (cond
                   ;; known methods
                   ((setf tmp (find-swf-method name *symbol-table*))
                    nil)
                   ;; known static methods
                   ((setf tmp (find-swf-static-method name *symbol-table*))
                    nil)
                   ;; known functions
                   ((setf tmp (find-swf-function name *symbol-table*))
                    (pushnew (car tmp) *ir2-function-deps* :test 'equal))
                   ;; unknown function...
                   (t
                    (pushnew name *ir2-function-deps* :test 'equal))))))
    (super whole))
   ((%asm forms)
    (labels ((recur-%asm (ops)
               (loop for i in ops
                  when (member (car i) '(:construct-prop
                                         :@mark-class-dependency))
                  do (pushnew (second i) *ir2-class-deps* :test 'equal)
                  else when (eq (car i) :%push-arglist)
                  do (recur-%asm (cdr i)))))
      (recur-%asm forms)
      (super whole)))
))



;;; skipping serious optimization/type inference for now, so
;;; just compile ir1 directly to asm to try to get something useable
;;; if not super-fast for now...
(defpackage #:uninterned (:use))
(defparameter *ir1-dest-type* nil)
;; alist of (block-name . return-type)
(defparameter *ir1-block-dest-type* nil)
(defparameter *current-local-index* nil)
(defparameter *current-closure-scope-index* nil)
(defparameter *activation-local-name* nil)
(defparameter *live-locals* nil)
(defparameter *scope-live-locals* nil)
(defparameter *literals-local* nil)
;; we don't combine literals at compile time anymore, so keep track
;; of which have been seen so far for breaking circularity
(defparameter *literals-seen* nil)
(defun upgraded-type (type)
  (when (and (listp type) (= 1 (length type)))
    (setf type (car type)))
  (case type
    ((fixnum :int) :int)
    ((real single-float float double-float short-float long-float) :number)
    (t type)))

(defun coerce-type ()
  (let ((utype (upgraded-type *ir1-dest-type*)))
    #++(unless (position utype '(:ignored t nil))
         (format t "coerce type to ~s~%" utype))
    (cond
      ((eq utype nil) nil)
      ((eq utype :ignored) '((:pop)))
      ((eq utype 'fixnum) '((:convert-integer)))
      ((eq utype :int) '((:convert-integer)))
      ((eq utype :uint) '((:convert-unsigned)))
      ((eq utype :double) '((:convert-double)))
      ((eq utype :number) '((:convert-double)))
      ;; :coerce-string converts null->"null",
      ;;     undefined->"undefined"
      ;; :convert-string converts both to NULL
      ((eq utype :string) '((:convert-string)))
      ((eq utype :bool) '((:convert-boolean)))
      ((eq utype t) '((:coerce-any)))
      (t '((:coerce-any))))))

(defun add-function-ref (name)
  (pushnew name *ir2-function-deps* :test 'equal))

(defun add-class-ref (name)
  (pushnew name *ir2-class-deps* :test 'equal))

(defun literal-add (value code)
  #++(coalesce-literal value code)
  `(;(:get-local ,*literals-local*)
    #++(:push-int ,(coalesce-literal value code))
    (:%literal-add ,value ,code)
    #++(:get-property (:multiname-l "" ""))))

(defun literal-ref* (value)
  ;; for literals we have already seen
  `((:get-local ,*literals-local*)
    (:%literal-ref* ,value)
    (:get-property (:multiname-l "" ""))))

;; literals referenced in current function
;;   list of object and code to build object (except any circular references)
(defparameter *function-literals* nil)
;; instructions for adding circular refs once objects have been created
;;   list of object and code to add circular links
(defparameter *function-circularity-fixups* nil)

(defun compile-literal (value)
  ;; to compile a literal:
  ;;   if simple, just return code
  ;;   if directly circular
  ;;      replace circularity with NIL
  ;;      add circularity fixup
  ;;      compile rest as normal
  ;;   if not directly circular (or circularity removed in previous step)
  ;;      increment ref count in 'seen' hash
  ;;      compile components recursively
  ;;      add code to compile current object
  ;;      decrement ref count
  (let ((refs nil)
        ;; we use 2 hash tables, *literals-seen* is bound at a higher
        ;; level, and used to avoid dumping the same object multiple times
        ;; (probably could skip that, since the extras will be coalesced later
        ;;  but probably faster to catch it earlier)
        ;; and one checking for circular references within a specific object
        (circularity-hash (make-hash-table :test #'eq)))
    (macrolet ((with-ref ((value) &body body)
                 `(unwind-protect
                       (progn
                         (setf (gethash ,value *literals-seen*) t)
                         (incf (gethash ,value circularity-hash 0))
                         ,@body)
                    (decf (gethash ,value circularity-hash nil)))))
      (labels ((circular (value)
                 (plusp (gethash value circularity-hash 0)))
               (seen (value)
                 (or (circular value)
                     (gethash value *literals-seen*)))
               (compile-simple (value)
                 (typecase value
                   (integer
                    (cond
                      ((< (- (expt 2 31)) value (expt 2 31))
                       `((:push-int ,value)))
                      ((< 0 value (expt 2 32))
                       `((:push-uint ,value)))
                      (t
                       (warn "storing integer ~s as double" value)
                       `((:push-double ,(float value 1d0))))))
                   (real
                    `((:push-double ,(float value 1d0))))
                   (string
                    `((:push-string ,value)))
                   (simple-vector
                    (literal-ref* value))
                   (symbol
                    (cond
                      ((eq value t)
                       `((:push-true)))
                      ((eq value nil)
                       `((:push-null)))
                      (t
                       (literal-ref* value))))
                   (cons
                    (literal-ref* value))
                   (t
                    (error "don't know how to compile quoted value ~s" value))))
               (add-circular-vector (parent fixups)
                 (assert fixups)
                 (push (list parent
                             `(,@(compile-simple parent)
                                 ,@(loop for (index v) in fixups
                                      collect `((:dup)
                                                (:push-int ,index)
                                                ,@(compile-simple v)
                                                (:set-property (:multiname-l "" ""))))
                                 (:pop)))
                       *function-circularity-fixups*))
               (add-circular-cons (parent car cdr)
                 (assert (or car cdr))
                 (push (list parent
                             `(,@(compile-simple parent)
                                 ,@ (when car
                                      `(,@ (when cdr `((:dup)))
                                           ,@ (compile-simple car)
                                           (:set-property %car)))
                                 ,@ (when cdr
                                      `(,@ (compile-simple cdr)
                                           (:set-property %cdr)))))
                       *function-circularity-fixups*))
               (literal-add (value code)
                 (push (list value code) *function-literals*))
               (compile-compound (value)
                 (typecase value
                   (simple-vector
                    (unless (seen value)
                      (with-ref (value)
                        (let ((*literals-local* 1))
                          (loop for i across value
                             for index from 0
                             if (circular i)
                             collect (list index i) into fixups
                             else do (compile-compound i)
                             finally (when fixups
                                       (add-circular-vector value fixups))))
                        (literal-add
                         value
                         `(,@(loop for i across value
                                if (circular i)
                                append (compile-simple NIL)
                                else append (compile-simple i)
                                collect '(:coerce-any))
                             (:new-array ,(length value)))))))
                   (symbol
                    ;; don't need circularity checking for symbols...
                    (unless (gethash value *literals-seen*)
                      (setf (gethash value *literals-seen*) t)
                      (cond
                        ((eq value t)
                         `((:push-true)))
                        ((eq value nil)
                         `((:push-null)))
                        (t
                         (add-function-ref '%intern)
                         (literal-add
                          value
                          `((:find-property-strict %intern)
                            ;; fixme: handle symbols properly
                            (:push-string ,(package-name (or (symbol-package value) :uninterned)))
                            (:push-string ,(symbol-name value))
                            (:call-property %intern 2)))))))
                   (cons
                    (add-class-ref 'cons-type)
                    (unless (seen value)
                      (with-ref (value)
                        (let ((*literals-local* 1)
                              (circular-car (circular (car value)))
                              (circular-cdr (circular (cdr value))))
                          (unless circular-car
                            (compile-compound (car value)))
                          (unless circular-cdr
                            (compile-compound (cdr value)))
                          (when (or circular-car circular-cdr)
                            (add-circular-cons value
                                               (when circular-car (car value))
                                               (when circular-cdr (cdr value)))))
                        (push value refs)
                        (literal-add
                         value
                         (append
                          `((:find-property-strict cons-type)
                            ,@(if (circular (car value))
                                  (compile-simple nil)
                                  (compile-simple (car value)))
                            ,@(if (circular (cdr value))
                                  (compile-simple nil)
                                  (compile-simple (cdr value)))
                            (:construct-prop cons-type 2)))))))
                   (t (compile-simple value)))))
        (let ((*literals-local* 1))
          (compile-compound value))
        `(,@(compile-simple value)
            ,@(coerce-type))))))


(define-structured-walker assemble-ir1 null-ir1-walker
  :form-var whole
  :labels (
           (set-var-info (var flag value)
                         (setf (getf (getf *ir1-var-info* var nil) flag) value))
           (get-var-info (var flag &optional default)
                         (getf (getf *ir1-var-info* var nil) flag default))
           (get-tag-info (tag flag &optional default)
                         (getf (getf *ir1-tag-info* tag nil) flag default))
           (get-fun-info (name flag &optional default)
                         (getf (getf *ir1-fun-info* name nil) flag default))
           (recur-progn (body)
                        (if body
                            (loop for (form . more) on body
                                  if more
                                  append (let ((*ir1-dest-type* :ignored))
                                           `(,@(recur form)
                                               ))
                                  else append (recur form))
                            `((:push-null)
                              ,@(coerce-type))))
           (get-local-index (var)
                            (assert var)
                            (or (get-var-info var :index nil)
                                (set-var-info var :index (1- (incf *current-local-index*)))))
           (get-closure-index (var)
                              (second (assoc var *current-closure-vars*)))
           (call-name (form)
                      (and (eq (car form) '%call)
                           (getf (cdr form) 'name)))
       )
  :forms
  (((quote value)
    (compile-literal value))

     ;; type = :local , :normal , :setf , ??
     ;; (:local possibly should be :static, but might want to distinguish based
     ;;  on what we pass as THIS arg? :local would get current function's THIS
     ;;  while :static would get global scope or something?)
     ((%call type name args)
      #++(format t "call ~s~%" name)
      (ecase type
        ;; todo: void calls if no dest? (or make sure peephole handles it?)
        (:normal
         (let (tmp)
           (cond
            ;; known methods
            ((setf tmp (find-swf-method name *symbol-table*))
             (add-function-ref tmp)
             #++(format t "normal method call ~s = ~s~%" name tmp)
             `(,@(let ((*ir1-dest-type* nil))
                      (recur (first args)))
                 ,@(let ((*ir1-dest-type* nil))
                        (loop for a in (cdr args)
                              append (recur a)))
                 (:call-property ,tmp ,(length (cdr args)))
                 ,@(coerce-type)))
            ;; known static methods
            ((setf tmp (find-swf-static-method name *symbol-table*))
             (add-class-ref (first tmp))
             #++(format t "static method call ~s = ~s~%" name tmp)
             `(;#+nil(:find-property-strict ,(car tmp)) ;;??
               (:get-lex ,(if (find-swf-class (car tmp))
                              (swf-name (find-swf-class (car tmp)))
                              (car tmp)))
               ,@(let ((*ir1-dest-type* nil))
                      (loop for a in args
                            append (recur a)))
                 (:call-property ,(second tmp) ,(length args))
               ,@(coerce-type)))
            ;; known functions
            ;; todo: benchmark :find-property-strict vs. :get-global-scope
            ;; for functions known to be on global object, and optimize
            ;; that case if useful
            ((setf tmp (find-swf-function name *symbol-table*))
             (add-function-ref (car tmp))
             #++(format t "function call ~s = ~s~%" name tmp)
             ;; :find-property-strict needed for stuff like %flash:trace
             `((:find-property-strict ,(car tmp)) ;(:get-global-scope)
               ,@(let ((*ir1-dest-type* nil))
                      (loop for a in args
                         append (recur a)))
               (:call-property ,(car tmp) ,(length args))
                 ,@(coerce-type)))
            ;; unknown function... call directly
            (t
             #++(format t " unknown function")
             (add-function-ref name)
             ;; fixme: is this correct?
             `(#+nil(:find-property-strict ,name)
                    (:get-global-scope)
               ,@(let ((*ir1-dest-type* nil))
                      (loop for a in args
                            append (recur a)))
               (:call-property ,name ,(length args))
               ,@(coerce-type))))))
        (:local
         (if (get-fun-info name :closure)
             ;; closures need to be called specially
             `((:comment "local call - closure")
               ,@(let ((*ir1-dest-type* nil))
                      (recur name))
               (:get-local 0)
               ,@(let ((*ir1-dest-type* nil))
                      (loop for a in args
                            append (recur a)))
               (:call ,(length args))
               ,@(coerce-type))
             ;; local functions without free vars can be called directly
             #++`((:get-local 0)
               ,@(let ((*ir1-dest-type* nil))
                      (loop for a in args
                            append (recur a)))
               (:call-static ,name ,(length args))
               ,@(coerce-type))
             ;; or not? possibly shouldn't be adding (:anonymous t) to
             ;; non-closure local functions?
             `((:comment "local call")
               ,@ (let ((*ir1-dest-type* nil))
                    (recur name))
               (:get-local 0)
               ,@ (let ((*ir1-dest-type* nil))
                    (let ((foo (loop for a in args
                                  append (recur a))))
                      (assert (>= (length foo) (length args)))
                      foo))
               (:call ,(length args))
               ,@(coerce-type))
))
        (:setf (if (find-swf-property name)
                   ;; hack to autodefine implicit setf functions for known
                   ;; properties
                   ;; name = property name
                   ;; args = value, object
                   (progn
                     ;; fixme: look up correct type if any for
                     ;; properties?  -- need to cast separately
                     ;; though, since return value might be different
                     ;; type...
                     `(,@(let ((*ir1-dest-type* nil))
                              (recur (first args))) ; value
                         ;; extra copy for return value
                         ,@(unless (eq *ir1-dest-type* :ignored)
                                   `((:dup)))
                         ,@(let ((*ir1-dest-type* nil))
                                (recur (second args))) ; object
                         (:swap)
                         (:set-property ,(or (find-swf-property name) name))
                         ,@(unless (eq *ir1-dest-type* :ignored)
                                   (coerce-type))))
                   (progn
                     (add-function-ref `(setf ,name))
                     (add-class-ref 'setf-namespace-type)
                     #++`((:get-lex setf-namespace-type)
                      ,@(let ((*ir1-dest-type* nil))
                             (loop for a in args
                                append (recur a)))
                      (:call-property ,name ,(length args))
                      ,@(coerce-type))
                     `((:get-lex setf-namespace-type)
                       (:get-property ,name)
                       (:get-global-scope)
                       ,@(let ((*ir1-dest-type* nil))
                              (loop for a in args
                                 append (recur a)))
                       (:call ,(length args))
                      ,@(coerce-type)))))))

     ;; possibly should split out closed and normal bindings, but for now
     ;; leaving combined to avoid worrying about order of evaluating the values
     ;; (might eventually want to assign a local for the closed vars anyway,
     ;;  if compiler gets smart enough to tell when nothing can be accessing
     ;;  them through the closure for a section of code? (and assuming going
     ;;  through the closure var is slow enough to care in the first place)
     ((%bind vars values types closed-vars body)
      (let ((*live-locals* *live-locals*))
       `(,@(loop for var in vars
              for val in values
              for closed = (when var (member var closed-vars))
              for var-type = (if var (get-var-info var :type t)
                                 :ignored)
              when var do (push (get-local-index var) *live-locals*)
              append (let ((*ir1-dest-type* var-type))
                       (recur val))
              ;; fixme: don't allocate a local for closure vars?
              when var collect `(:set-local ,(get-local-index var))
              when closed
              append `((:get-scope-object ,*current-closure-scope-index*)
                       (:get-local ,(get-local-index var))
                       ,@(unless (get-closure-index var) (error "error !! ~s" whole))
                       (:set-slot ,(get-closure-index var))))
           #++(:comment ,(format t "%bind live=~s" (mapcar (lambda (a)
                                                          (when a (list a (get-local-index a)))))))
           ,@(recur-progn body)
           ,@(loop for var in vars
                when var
                collect `(:kill ,(get-local-index var))))))

     ;; type = :local , :closure , ???
     ((%ref type var)
      (ecase type
        (:local `((:get-local ,(get-local-index var))
                  ,@(coerce-type)))
        (:lex `((:get-lex ,(first var))
                (:get-property ,(second var))
                ,@(coerce-type)))
        (:closure
         (let ((c (get-closure-index var)))
           (if c
               `((:get-scope-object ,*current-closure-scope-index*)
                 (:get-slot ,c)
                 ,@(coerce-type))
               `((:get-lex ,var)
                 ,@(coerce-type)))))))
     ((%set type var value)
      (ecase type
        ;; fixme: should these coerce the type after the dup instead of before?
        ;; fixme: possibly should factor out the recur + dup?
        (:local `(,@(cond
                     ;; hacks to allow (:@ (setf foo <value on top of stack>))
                     ;; in %asm
                     ((member (call-name value) '(%asm-top-of-stack-untyped
                                                  %asm-top-of-stack-typed))
                      nil)
                     ;; dest-type = nil since we might have different
                     ;; types for the var and return value
                     (t (let ((*ir1-dest-type* nil))
                          (recur value))))
                    ,@(unless (eq *ir1-dest-type* :ignored)
                              `((:dup)))
                    ;; add cast for the assignment if needed
                    ,@(unless (eq (call-name value) '%asm-top-of-stack-untyped)
                              (let ((*ir1-dest-type* (get-var-info var :type t)))
                                (coerce-type)))
                    (:set-local ,(get-local-index var))
                    ,@(unless (eq *ir1-dest-type* :ignored)
                              (coerce-type))))
        (:closure
         (let ((c (get-closure-index var)))
           `(,@(cond
                ;; hacks to allow (:@ (setf foo <value on top of stack>))
                ;; in %asm
                ((member (call-name value) '(%asm-top-of-stack-untyped
                                             %asm-top-of-stack-typed))
                 nil)
                ;; dest-type = nil since we might have different
                ;; types for the var and return value
                (t (let ((*ir1-dest-type* nil))
                     (recur value))))
               ,@(unless (eq *ir1-dest-type* :ignored)
                         `((:dup)))
               ;; add cast for the assignment if needed
               ,@(unless (eq (call-name value) '%asm-top-of-stack-untyped)
                         (let ((*ir1-dest-type* (get-var-info var :type t)))
                           (coerce-type)))
               ,@(if c
                     `((:get-scope-object ,*current-closure-scope-index*)
                       (:swap)
                       (:set-slot ,c))
                     `((:find-property-strict ,var)
                       (:swap)
                       (:set-property ,var)))
               ;; convert type of return value if needed
               ,@(unless (eq *ir1-dest-type* :ignored)
                         (coerce-type)))))))

     ((%named-lambda name flags lambda-list closed-vars types
                     activation-vars body)
      (let ((*ir1-in-tagbody* nil)
            (*current-local-index* 0)
            (*current-closure-vars* activation-vars)
            (*activation-local-name* (gensym "ACTIVATION-RECORD-"))
            (*current-closure-scope-index* 1)
            (*live-locals* nil)
            (*ir2-function-deps* (getf flags :function-deps))
            (*ir2-class-deps* (getf flags :class-deps))
            (*literals-local* nil)
            ;; possibly should move these (and *literals-seen*)
            ;; to compilation-unit level instead?
            (*function-literals* nil)
            (*function-circularity-fixups* nil)
            ;; fixme: should this be at higher (or lower?) level?
            (*literals-seen* (make-hash-table :test #'eq)))
        ;; fixme: implement this properly instead of relying on it picking right numbers on its own
        (loop for i in (lambda-list-vars lambda-list)
             ;; note: (get-local-index i) is needed for side effects
             ;; in addition to the live locals stuff
           do (push (get-local-index i) *live-locals*))
        #++(format t "named lambda ~s vars=~s~%" name (mapcar (lambda (a) (list a (get-local-index a))) (lambda-list-vars lambda-list)))
        (let ((activation
               `(,@(when activation-vars
                   `((:new-activation)
                     (:dup)
                     (:push-scope)
                     (:set-local ,(get-local-index *activation-local-name*))))
                 ,@(loop for var in closed-vars
                      append `((:comment "assign activation")
                               (:get-scope-object ,*current-closure-scope-index*)
                               (:get-local ,(get-local-index var))
                               (:set-slot ,(get-closure-index var))))))
              (asm (append
                    ;; fixme: check for actually using any literals
                    ;; before caching the object in a local
                    (when t ;; todo: only cache literals object if used
                      `((:find-property ,(literals-global-name *compiler-context*))
                        (:get-property ,(literals-global-name *compiler-context*))
                        (:set-local
                         ,(setf *literals-local* (get-local-index (gensym))))))
                    (recur-progn body)))
              (arg-types (loop ;for i in (lambda-list-vars lambda-list)
                            ;for decl = (getf types i)
                            for decl in types
                            for utype = (upgraded-type decl)
                            for type = (cond
                                         ((find-swf-class utype)
                                          (swf-name (find-swf-class utype)))
                                         ((eq utype :double)
                                             "Number")
                                         ((eq utype :number)
                                             "Number")
                                         (t utype))
                            collect (if (member type '(t '* :*))
                                        0
                                        type))))
          #++(format t "arg-types = ~s, vars=~s decl=~s~%" arg-types (lambda-list-vars lambda-list) types)
          (setf asm
                (loop
                   with found = nil
                   for i in asm
                   when (and (consp i) (eq (car i) :%activation-record))
                   append activation into a
                   and do (setf found t)
                   else collect i into a
                   finally (return (if found
                                       a
                                       (append activation a)))))
          (setf (getf flags :function-deps) *ir2-function-deps*)
          (setf (getf flags :class-deps) *ir2-class-deps*)
          `(%named-lambda
                   name ,name
               flags ,flags
               lambda-list ,lambda-list
               types ,arg-types
               closed-vars ,closed-vars
               activation-vars ,activation-vars
               literals ,(list *function-literals* *function-circularity-fixups*)
               body ,asm))))

     ((function type name)
      (ecase type
        (:local
         (add-function-ref name)
         `((:new-function ,name)
           ,@(coerce-type)))
        (:normal (let (tmp)
                   ;; fixme: share code with function calls?
                   (cond
                     ;; known methods
                     ((setf tmp (find-swf-method name *symbol-table*))
                      (add-function-ref tmp)
                      `((:get-property ,tmp)
                        ,@(coerce-type)))
                     ;; known static methods
                     ((setf tmp (find-swf-static-method name *symbol-table*))
                      (add-class-ref (first tmp))
                      `( ;#+nil(:find-property-strict ,(car tmp)) ;;??
                        (:get-lex ,(if (find-swf-class (car tmp))
                                       (swf-name (find-swf-class (car tmp)))
                                       (car tmp)))
                        (:get-property ,(second tmp))
                        ,@(coerce-type)))
                     ;; known functions
                     ((setf tmp (find-swf-function name *symbol-table*))
                      (add-function-ref (car tmp))
                      ;; :find-property-strict needed for stuff like %flash:trace
                      `((:find-property-strict ,(car tmp)) ;(:get-global-scope)
                        (:get-property ,(car tmp))
                        ,@(coerce-type)))
                     ;; unknown function... call directly
                     (t
                      (add-function-ref name)
                      ;; fixme: is this correct?
                      `(#+nil(:find-property-strict ,name)
                             (:get-global-scope)
                             (:get-property ,name)
                             ,@(coerce-type)))))
         )
        (:method (error "method calls with object not done yet..."))))

     ;; common code for nlx handling in catch/return/tagbody
     ((%catch type body tag-code tag-property handler-code)
      (let ((start (gensym "CATCH-START-"))
            (end (gensym "CATCH-END-"))
            (name (gensym "CATCH-NAME-"))
            (jump (gensym "CATCH-JUMP-"))
            (jump2 (gensym "CATCH-JUMP2-")))
        ;;fixme: add avm2 level set of throw/catch ops, and implement with those
        ;;fixme: may need to store value in a temp instead of leaving on stack?
        `((:%dlabel ,start)
          (:comment "body start")
          ,@body
          ;;,@(coerce-type)
          (:comment "body end")
          (:%dlabel ,end)
          (:jump ,jump2)
          ;; start exception handler block
          (:%exception ,name ,start ,end ,type)
          ;; restore scope stack
          (:get-local 0)
          (:push-scope)
          ,@(when *current-closure-vars*
                  `((:get-local ,(get-local-index *activation-local-name*))
                    (:push-scope)))
          ;; test to see if exception was for us (matching tag)
          (:dup)
          (:get-property ,tag-property)

          ;;(:comment "debug")
          ;;(:dup)
          ;;(:find-property-strict :trace)
          ;;(:swap)
          ;;(:push-string "caught :")
          ;;(:swap)
          ;;(:add)
          ;;(:call-property :trace 1)
          ;;(:pop)

          (:comment "tag start")
          ,@tag-code
          (:comment "tag end")

          ;;(:comment "debug2")
          ;;(:dup)
          ;;(:find-property-strict :trace)
          ;;(:swap)
          ;;(:push-string "checing against tag :")
          ;;(:swap)
          ;;(:add)
          ;;(:call-property :trace 1)
          ;;(:pop)

          (:if-strict-eq ,jump)
          ;;(:push-int 12345)
          (:throw)
          (:%dlabel ,jump)
          (:comment "handler start")
          ,@handler-code
          (:comment "handler end")
          (:%dlabel ,jump2))))

     ((block name nlx forms)
      ;; we need to enforce a common type for all exits from block,
      ;; so set to T if we don't have anything more specific
      ;; (we removed blocks without multiple returns in an earlier pass
      ;;  so hopefully won't slow anything down in the normal case,
      ;;  and eventually type inference can improve the case where all
      ;;  branches return a compatible type)
      (let* ((*ir1-dest-type* (or *ir1-dest-type* t))
             (*ir1-block-dest-type* (cons (cons name *ir1-dest-type*)
                                         *ir1-block-dest-type*))
             (*scope-live-locals* (cons (cons name *live-locals*)
                                        *scope-live-locals*)))
        (if nlx
           ;; fixme: return to correct dynamic scope corresponding to the entry from which the return-from was created...
           (recur
            `(%catch type block-exception-type
                     tag-property block-exception-tag
                     body ,(recur-progn forms)
                     ;; fixme: is this right type? should fix THROW if changed...
                     tag-code ,(let ((*ir1-dest-type* nil)
                                     (exit-point (get-tag-info
                                                  name :exit-point-var)))
                                    (recur `(%ref type ,(get-var-info
                                                         exit-point
                                                         :ref-type :local)
                                                  var ,exit-point)))
                     handler-code ((:get-property block-exception-value)
                                   ,@(coerce-type))))
           `(,@(recur-progn forms)
               (:%dlabel ,name)))))
     ((return-from name value)
      (let* ((scope-locals (cdr (assoc name *scope-live-locals*)))
             (live (set-difference *live-locals* scope-locals)))
        #++(format t "return-from: live=~s~%" live)
       `((:comment "local return-from" ,name)
         ,@(let ((*ir1-dest-type* (cdr (assoc name *ir1-block-dest-type*))))
                (recur value))
         ,@(when live
                 (loop for i in live
                    collect `(:kill ,i)))
         (:jump ,name))))

     ((tagbody name nlx forms)
      (loop for i in forms
         when (atom i)
         do (push (cons i *live-locals*) *scope-live-locals*))
      (let ((*scope-live-locals* *scope-live-locals*))
        (if nlx
            (let ((bad-nlx-label (gensym "TAGBODY-BUG-")))
              (recur
               `(%catch type go-exception-type
                        tag-property go-exception-tag
                        body (,@(loop for i in forms
                                   when (atom i)
                                   collect `(:%label ,i)
                                   else append (let ((*ir1-dest-type* :ignored))
                                                 (recur i)))
                                (:push-null)
                                ,@(coerce-type))
                        tag-code ,(let ((*ir1-dest-type* nil))
                                       (recur `(%ref type ,(get-var-info
                                                            name
                                                            :ref-type :local)
                                                     var ,name)))
                        handler-code
                        ((:get-property go-exception-index)
                         (:convert-integer)
                         (:lookup-switch
                          ,bad-nlx-label
                          ,(mapcar 'second
                                   (sort (loop for i in forms
                                            when (atom i)
                                            collect `(,(get-tag-info i :nlx-index)
                                                       ,i))
                                         #'< :key #'car)))
                         (:%dlabel ,bad-nlx-label)
                         (:push-string "broken tagbody!")
                         (:throw)
                         (:push-null)
                         ,@(coerce-type)))))
            `(,@(loop for i in forms
                   when (atom i)
                   collect `(:%label ,i)
                   else append (let ((*ir1-dest-type* :ignored))
                                 (recur i)))
                (:push-null)
                ,@(coerce-type)))))
     ((go tag)
      (let* ((scope-locals (cdr (assoc tag *scope-live-locals*)))
             (live (set-difference *live-locals* scope-locals)))
        #++(format t "go ~s: live=~s~%  tagbody=~s,live=~s,tag-live=~s~%"
                tag live
                (get-tag-info tag :exit-point-var)
                *live-locals*
                (assoc tag *scope-live-locals*)
                )
        #++(format t "sll=~s~%" *scope-live-locals*)
        `(,@(when live
                  (loop for i in live
                     collect `(:kill ,i)))
            (:jump ,tag))))

     ((catch tag forms)
      (recur
       `(%catch type throw-exception-type
                tag-property throw-exception-tag
                body ,(recur-progn forms)
                ;; fixme: is this right type? should fix THROW if changed...
                tag-code ,(let ((*ir1-dest-type* nil))
                               (recur tag))
                handler-code ((:get-property throw-exception-value)
                              ,@(coerce-type)))))
     ((throw tag result-form)
      (error "got throw, expected it to be handled by %nlx?"))

;;; combined tag for non-local return-from, go, throw in later passes
     ((%nlx type name exit-point value)
      (ecase type
        (:go
         (add-class-ref 'go-exception-type)
         `((:find-property-strict go-exception-type)
               ,@(let ((*ir1-dest-type* nil))
                      (recur exit-point))
               ,@(let ((*ir1-dest-type* nil))
                      `((:push-int ,(get-tag-info name :nlx-index))))
               (:construct-prop go-exception-type 2)
               (:throw)))
        (:return-from
         (add-class-ref 'block-exception-type)
          `((:comment "nlx return-from" ,name)
            (:find-property-strict block-exception-type)
            ;; fixme: check these types
            ,@(let ((*ir1-dest-type* nil))
                   (recur exit-point))
            ,@(let ((*ir1-dest-type* t))
                   (recur value))
            (:construct-prop block-exception-type 2)
            (:throw)))
        (:throw
            (add-class-ref 'throw-exception-type)
          `((:find-property-strict throw-exception-type)
            ;; fixme: should this specify a type (or t)?
            ,@(let ((*ir1-dest-type* nil))
                   (recur exit-point))
            ;; fixme: not sure about correct type for this either...
            ,@(let ((*ir1-dest-type* t))
                   (recur value))
            (:construct-prop throw-exception-type 2)
            (:throw)))))

   ;; todo: probably should add a strict-= version of IF for
   ;; performance sensitive stuff?
     ((if condition then else)
      (let ((else-label (gensym "IF-ELSE-"))
            (done-label (gensym "IF-DONE-"))
            ;; for now always coerce to * if we don't have a more specific type,
            ;; to avoid conflicts between branches
            ;; fixme: derive types for branches and skip this if they match
            (*ir1-dest-type* (or *ir1-dest-type* t)))
;;; fixme: decide how to implement IF
        ;; possibly should eval condition with no type, and then
        ;; (:push-null) (:if-eq) instead of (:if-false)?
        `(#+nil,@(let ((*ir1-dest-type* :bool))
                      (recur condition))
               #+nil  (:if-false ,else-label)
               ,@(let ((*ir1-dest-type* nil))
                      (recur condition))
               (:dup)
               (:push-null)
               (:strict-equals)
               (:swap)
               (:push-false)
               (:strict-equals)
               (:bit-or)
               (:if-true ,else-label)
               ,@(recur then)
               (:jump ,done-label)
               (:%dlabel ,else-label)
               ,@(recur else)
               (:%dlabel ,done-label))))

     ((progn body)
      `(,@(recur-progn body)))

     ((unwind-protect protected cleanup)
      ;; can this be combined with the catch stuff?
      (let ((start (gensym "UWP-START-"))
            (end (gensym "UWP-END-"))
            (name (gensym "UWP-NAME-"))
            (jump (gensym "UWP-JUMP-"))
            (end-2 (gensym "UWP-END2-")))
        ;;fixme: may need to store value in a temp instead of leaving on stack?
        `((:%dlabel ,start)
          (:comment "body start")
          ;; fixme: probably should store this in a typed local so it
          ;; doesn't need to match the exception object on the stack
          ;; at the cleanup label once we start using more specific
          ;; types
          ,@ (let ((*ir1-dest-type* t))
               (recur protected))
          (:comment "body end")
          (:%dlabel ,end)
          ;; normal exit
          (:push-false)
          ;;(:set-local ,(get-local-index nlx-flag))
          (:jump ,jump)
          ;; start exception handler block
          (:%exception ,name ,start ,end 0) ;; catch anything
          ;; restore scope stack
          (:get-local 0)
          (:push-scope)
          ,@(when *current-closure-vars*
                  `((:get-local ,(get-local-index *activation-local-name*))
                    (:push-scope)))
          ;; we don't want to duplicate the cleanup code (or if we do
          ;; duplicate it, we need to deal with duplicated labels in
          ;; the cleanup code), so we set a flag to indicate it should
          ;; throw the result instead of returning it at the end
          (:coerce-any)
          (:push-true)
          ;; cleanup
          (:%dlabel ,jump)
          ,@(let ((*ir1-dest-type* :ignored))
                 (loop for f in cleanup
                       append (recur f)))
          ;; top of stack = exception flag, next = exception or result
          (:if-false ,end-2)
          (:throw)
          (:%dlabel ,end-2)
          ,@(coerce-type)
          (:comment "handler end"))))

     ((%compilation-unit var-info tag-info fun-info lambdas)
      (let ((*ir1-tag-info* tag-info)
            (*ir1-var-info* var-info)
            (*ir1-fun-info* fun-info)
            (*live-locals* nil)
            (*scope-live-locals* nil))
        `(%compilation-unit
          var-info ,var-info
          tag-info ,tag-info
          fun-info ,fun-info
          lambdas ,(recur-all lambdas))))

   ((%asm forms)
      ;; fixme: decide correct handling of return type?
      (labels ((recur-%asm (ops)
                 (loop for i in ops
                    ;; fixme: convert this into something better
                    ;; suited for selecting from a list of special
                    ;; cases...
                    when (eq (car i) :@mark-class-dependency)
                    do ;; don't collect anything, just mark class as used
                      (add-class-ref (second i))
                    else when (eq (car i) :construct-prop)
                    do (add-class-ref (second i))
                    and collect i
                    else when (eq (car i) :@)
                    append (let ((*ir1-dest-type* (third i)))
                             (recur (second i)))
                    else when (eq (car i) :%restore-scope-stack)
                    append `((:get-local 0)
                             (:push-scope)
                             ,@ (when *current-closure-vars*
                                  `((:get-local ,(get-local-index
                                                  *activation-local-name*))
                                    (:push-scope))))
                    else when (eq (car i) :@kill)
                    collect `(:kill ,(get-local-index (second i)))
                    else when (eq (car i) :%push-arglist)
                    append (recur-%asm (cdr i))
                    else collect i)))
        `(,@(recur-%asm forms)
            ,@(coerce-type))))

     ;; todo:

     ;;       ((load-time-value form &optional read-only-p)
     ;;        `(load-time-value ,(recur form) ,read-only-p))
     ;;       ((eval-when (&rest when) &rest forms)
     ;;        `(eval-when ,when ,@(recur-all forms)))
     ;;       ((locally &rest declarations-and-forms)
     ;;        `(locally ,@(recur-all declarations-and-forms)))
     ;;       ((multiple-value-call function-form &rest forms)
     ;;        ;; fixme: is this right?
     ;;        `(multiple-value-call ,(recur function-form) ,@(recur-all forms)))
     ;;       ((the value-type form)
     ;;        `(the ,value-type ,(recur form)))

     ;;       ((multiple-value-prog1 first-form &rest forms)
     ;;        `(multiple-value-prog1 ,(recur first-form) ,@(recur-all forms)))
     ;;       ((progv symbols values &rest forms)
     ;;        `(progv
     ;;             (,@(recur-all symbols))
     ;;             (,@(recur-all values))
     ;;           ,@(recur-all forms)))
     ;;
     ;;       ;; hack to simplify handling of places where declarations are allowed
     ;;       ;; fixme: add a declaration validation pass or something
     ;;       ((declare &rest declarations)
     ;;        `(declare ,declarations))
     ;;
     ;;       ;; anything else, evaluate all args
     ;;       (t
     ;;        `(,(car whole) ,@(recur-all (cdr whole))))
     ))

;;; fixme: figure out how to handle this better
#++(avm2-asm::define-asm-macro :%literal-ref (value code)
  (declare (ignorable code))
  #++(format t "literal ref ~s ~s -> ~s~%" value code (avm2-compiler::coalesce-literal value code))
  (labels ((add-deps (value code)
             (loop for i in code
                when (and (consp i) (eq (car i) :%literal-ref))
                do (add-deps (second i) (third i)))
             (coalesce-literal value code)))
    (avm2-asm::%assemble
     `((:push-int ,(add-deps value code))))))

#++
(avm2-asm::define-asm-macro-stack :%literal-ref (value code)
  (declare (ignorable value code))
  ;;pop push pop-scope push-scope rlocals wlocals klocals flags control-flow labels)
  (values 0 1  0 0  nil nil nil  0 nil nil))


(avm2-asm::define-asm-macro :%literal-add (value code)
  (declare (ignorable code))
  (labels ((add-deps (value code)
             (loop for i in code
                when (and (consp i) (eq (car i) :%literal-ref))
                do (add-deps (second i) (third i)))
             (coalesce-literal value code)))
    #++(add-deps value code)
    (coalesce-literal value code)
    nil))

(avm2-asm::define-asm-macro-stack :%literal-add (value code)
  (declare (ignorable value code))
  ;;pop push pop-scope push-scope rlocals wlocals klocals flags control-flow labels)
  (values 0 0  0 0  nil nil nil  0 nil nil))

(avm2-asm::define-asm-macro :%literal-ref* (value)
  (avm2-asm::%assemble
   `((:push-int ,(find-literal value)))))

(avm2-asm::define-asm-macro-stack :%literal-ref* (value)
  (declare (ignorable value))
  (values 0 1  0 0  nil nil nil  0 nil nil))

(defparameter *ir1-dump-asm* nil)
(defun c2 (form &optional (top-level-name :top-level))
  (let* ((*new-compiler* t)
         (form `(%compilation-unit (%named-lambda ,top-level-name (:trait ,top-level-name :trait-type :function) () ,form)))
         (assembled
          (passes form (append *ir1-passes* '(mark-activations
                                              ir2-mark-spilled-args
                                              assemble-ir1)))))
    (when *ir1-dump-asm* (format t "assembly dump:~%~s~%" assembled))
    assembled))

;;(c2 ''1)
;;(c2 ''a)
;;(c2 ''(1 2))
;;(c2 ''(1 . 2))
;;(c2 '#(1 2))
;;(c2 ''#(1 2))
;;(c2 '(vector 1 2))
;;(c2 '(progn 1))
;;(c2 '(progn 1 2 3))
;;(c2 '(progn (progn 1 2) 'a (+ 2 3) (progn 3)))
;;(c2 '(let ((a 1)) a))
;;(with-tags '(a) (c2 '(go b))) ;; expected error
;;(with-tags '(a) (c2 '(go a)))
;;(c2 '(tagbody foo (go baz) baz))
;;(c2 '(tagbody 1 (go 2) 2))
;;(c2 '(symbol-macrolet ((a 'foo)) a))
;;(c2 '(symbol-macrolet ((a (foo 123))) (+ a 1)))
;;(c2 '(symbol-macrolet ((a (foo 123))) (setq a 1)))
;;(c2 '(symbol-macrolet ((a (foo 123))) (let ((b 2)) (setq a 1 b 3))))
;;(c2 '(macrolet ((x (a) `(list ,a))) (x 123)))
;;(c2 '(macrolet ((x (a) (return-from x (list 'list 234 a)) `(list ,a))) (x 123)))
;;(with-local-vars (alphatize-var-names '(a)) (c2 'a))
;;(with-local-vars (alphatize-var-names '(a)) (c2 '(let ((a a) (b 'a)) a)))
;;(with-local-vars (alphatize-var-names '(a)) (c2 '(setq a 1)))
;;(c2 '(setq))
;;(c2 '(let ((a 2)) (setq a 1)))
;;(c2 '(symbol-macrolet ((x 'foo)) (list x (let ((x 'bar)) x))))
;;(c2 '(block x (return-from x)))
;;(c2 '(block x (return-from x 123)))
;;(c2 '(let ((x (block x (+ 1 2) (return-from x 123)))) x))
;;(c2 '(let ((x (+ 1 2 3))) x))
;;(c2 '(let ((x (progn (+ 1 2) (foo) (+ 3 4))) x)))

;;(c2 '(labels ((x (a) (list a))) (x 123)))
;;(c2 '(flet ((x (a) (list a))) (x 123)))
;;(c2 '(flet ((x (a) (return-from x 1) (list a))) (x 123)))
;;(c2 '(labels ((x (a) (list (y a))) (y (a) (x a))) (x 123)))
;;(c2 '(flet ((x (a) (list (y a))) (y (a) (x a))) (x 123)))
;;(c2 '(function (lambda (x) (+ x 1))))
;;(c2 '(function foo))
;;(c2 '(labels ((x (a) (list (y a))) (y (a) (x a))) (function x)))
;;(c2 '(if t 1 2))
;;(c2 '(let ((a (if (foo) 1 2))) a))
;;(c2 '(return-from a 1)) ;; error
;;(c2 '(catch 'a (throw 'a 1)))
;;(c2 '(catch 1234 (throw 1234 1)))
;;(c2 '(let ((a (catch 'a (throw 'a 1)))) a))
;;(c2 '(tagbody (+ 1 2 (go foo) 3 4) foo))
;;(c2 '(tagbody (+ 1 2 (if (baz) 3 (go foo)) 4 5) foo))
;;(c2 '(let ((a 1) (b 2)) (lambda (a c) (+ a b c))))
;;(c2 '(+ 1 2 (block foo (flet ((bar () (return-from foo 3))) (bar))) 4 5))


;;(c2 '(let ((x 1)) (lambda (y) (+ x y))))
;;(c2 '(lambda (a) (lambda (b) (+ a b))))
;;(c2 '(lambda (a) (let ((j 123)) (lambda (b) (+ a b j)))))

;;(c2 '(lambda (a) (tagbody (let ((j 123)) (lambda (b) (+ a b j))))))
;;(c2 '(lambda (a) (tagbody (let ((k 123)) (let ((j 1)) (let ((l k)) (lambda (b) (+ a b j))))))))
;;(c2 '(lambda (a) (tagbody foo (let ((k 123)) (let ((j 1)) (let ((l k)) (lambda (b) (if (zerop a) (go bar) (+ a b j)))))) bar)))

;;(c2 '(flet ((x (a) (list (y (return-from x 1) a))) (y (a) (x a))) #'x))

;;(c2 '(lambda (a) (lambda (x) (+ x a)) a))
;;(c2 '(lambda () (tagbody foo (go bar) bar (lambda () (go foo)))))

;;(c2 '(tagbody 1 (lambda (x) (go 1))))
;;(c2 '(lambda (x) (block blah 1)))
;;(c2 '(lambda (x) (block blah (block baz (return-from blah 2)))))
;;(c2 '(lambda (x) (block baz (block blah (lambda (x) (return-from blah 2))))))
;;(c2 '(block foo (progn 1 2) (block piyo (progn 1 (foo))) (progn (hoge) 3) (return-from foo 1)))
;;(c2 '(flet (((setf foo) (&rest r) r)) (setf (foo 1 2 3) 4))) ;;fixme
;;(c2 '(flet (((setf foo) (&rest r) r)) (function (setf foo)))) ;;fixme
;;(format t "~s~%" (cc ' (labels ((x (a) (+ (y (lambda (x) (return-from x (+ a x)))) 1000)) (y (a) (funcall a 10) 1)) #'x)))
(defparameter *top-level-function* nil)
(define-structured-walker finish-assembled-ir1 ()
  :forms
  (((%compilation-unit var-info tag-info lambdas)
    `(%compilation-unit
      var-info ,var-info
      tag-info ,tag-info
      lambdas ,(recur-all lambdas)))
       ((%named-lambda name flags lambda-list closed-vars types activation-vars literals body)
        ;; optionally add a call to this function to the top-level script-init
        ;; fixme: probably should store the name or a flag in the %compilation-unit instead of tracking it separately like this
        (when (eq name *top-level-function*)
          (setf (load-top-level *compiler-context*)
                ;; we call top-level function with 1 arg, the script object
                (append (load-top-level *compiler-context*)
                        `(
                          (:get-scope-object 0)
                          (:call-static ,name 0)
                          (:pop)))))
        (flet ((parse-arglist (args)
                 ;; fixme: add error checking, better lambda list parsing
                 (loop with rest = nil
                       with optional = nil
                       for i in args
                       when (eq i'&arest)
                       do
                       (setf rest i)
                       (setf i nil)
                       (setf optional nil)
                       when (eq i '&optional)
                       do
                       (setf optional t)
                       (setf i nil)
                       when (and i (not rest))
                       count 1 into count
                       when i
                       collect i into arg-names
                       and when optional
                       collect i into optional-names
                       finally (return (values arg-names count rest optional-names)))))

          (multiple-value-bind (names count rest-p optionals)
              ;; ignore the THIS arg added by compiler...
              (parse-arglist (cdr lambda-list))
            (declare (ignorable optionals))
            (when optionals (error "&optional args not supported yet"))
            (let ((r (getf flags :arest)))
              (when r
                ;; fixme: dump the arglist parsing stuff above, since it
                ;; should already be done...
                (when (and r rest-p)
                  (error "got &arest in arglist in ir2?"))
                (setf rest-p r)
                ;; drop &arest arg name from count of required args
                (decf count)))
            (let* ((asm (with-lambda-context (:args names :blocks nil)
                          `(,@(if (getf flags :no-auto-scope)
                                  `((:comment "skipping auto scope"))
                                  `((:get-local-0)
                                    (:push-scope)))
                              ,@body
                              ,@(unless (getf flags :no-auto-return)
                                        `((:return-value))))))
                   (activation-p (find :new-activation asm :key 'car))
                   (anonymous (getf flags :anonymous))
                   (return-type (getf flags :return-type)))
              (when *ir1-verbose*
                (format t "validate = ~s~%"
                        (multiple-value-list
                         (avm2-asm::%avm2-validate asm :arg-count
                                                  (+ 1
                                                     (if rest-p 1 0)
                                                     (length names))))))
              (loop for i in asm
                 when (eq (car i) :construct-prop)
                 do (pushnew (second i) (getf flags :class-deps) :test 'equal))
              (when (or (and activation-p (not activation-vars))
                        (and (not activation-p) activation-vars))
                ;; not completely sure this is an error, but shouldn't be
                ;; happening currently...
                #+nil(error "got :new-activation with no activation vars?"))
              (push
               ;; function data:
               ;;  swf name in format suitable for passing to asm (string/'(qname...))
               ;;  args to avm2-method:
               ;;    name id?
               ;;    list of arg types (probably all T/* for now)
               ;;    return type
               ;;    flags
               ;;    list of assembly
               ;;    ?
               (list
                (if (symbolp name) (avm2-asm::symbol-to-qname-list name) name)
                0 ;; name in method struct?
                (if types
                    (loop initially (assert (= count (length (cdr types))) ()
                                             "count ~s, types ~s" count types)
                       for i in (cdr types)
                       collect i) ;; arg types, 0 = t/*/any
                    (loop repeat count collect 0))
                (if return-type
                    return-type
                    0)                        ;; return type, 0 = any
                (logior (if rest-p #x04 0)    ;; flags, #x04 = &rest
                        (if activation-p #x02 0))
                asm
                :anonymous anonymous
                ;; fixme: should this just dump flags inline?
                :class-name (getf flags :class-name)
                :class-static (getf flags :class-static)
                :trait (getf flags :trait)
                :trait-type (getf flags :trait-type)
                :function-deps (getf flags :function-deps)
                :class-deps (getf flags :class-deps)
                :optional-args (getf flags :optional)
                :literals (first literals)
                :circularity-fixups (second literals)
                :activation-slots
                (when activation-vars
                  (loop for (name index) in activation-vars
                     ;; no type info for now..
                     collect `(,name ,index 0))))
               (gethash name (functions *symbol-table*) (list)))))))))

(defun c3 (name form)
  (finish-assembled-ir1 (c2 form name)))

(defmacro c3* (name &body forms)
  `(c3 ,name '(progn ,@forms)))

(defun c4 (name form)
  (let ((*top-level-function* name))
    (c3 name form)))


#++
(defun d2 (form)
  (let ((avm2-asm::*assembler-context* (make-instance 'avm2-asm::assembler-context))
        (*compiler-context* (make-instance 'compiler-context))
        (*symbol-table* (make-instance 'symbol-table :inherit
                                       (list *cl-symbol-table*))))
    (c2 form)))


#++
(print
 (d2 '(+ 123 (handler-case (foo) (t (1))) 234)))

#++
(print
 (d2 '(+ 123 (handler-case (foo) (t (1))))))

#++
(print
 (d2 '(progn (+ 123 (handler-case (foo) (t (1)))) "foo")))

#++
(print (d2 '(+ (block xxfoo (flet ((bar () (return-from xxfoo 100) 1000)) (bar) 10000)) 1)))

#++
(let ((*ir1-verbose* t))
  (d2 '(loop for i below 10
          when (oddp i)
          collect i)))